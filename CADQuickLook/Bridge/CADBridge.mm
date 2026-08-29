#include "CADBridge.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepBndLib.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom_Surface.hxx>
#include <IGESControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <ShapeProcess.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <IMeshTools_Parameters.hxx>
#include <STEPControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <RWStl.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <gp_Pnt2d.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_XYZ.hxx>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <filesystem>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

struct CADBridgeModel {
    TopoDS_Shape shape;
    std::vector<TopoDS_Face> faces;
    std::vector<TopoDS_Edge> edgeShapes;
    std::vector<CADVertex> vertices;
    std::vector<CADTriangle> triangles;
    std::vector<CADFaceRange> faceRanges;
    std::vector<CADPoint3D> polylinePoints;
    std::vector<CADEdgePolyline> edges;
    CADBounds bounds{};
    CADModelStats stats{};
    std::string error;

    CADBridgeProgressCallback progressCallback = nullptr;
    void *progressContext = nullptr;
    std::mutex progressMutex;
    CADLoadStage lastStage = CADLoadStageReading;
    double lastFraction = -2.0;
};

namespace {

// Forwards progress to the host, throttled to stage changes and 1% steps.
void reportProgress(CADBridgeModel& model, CADLoadStage stage, double fraction, uint32_t count = 0) {
    if (!model.progressCallback) return;
    std::lock_guard<std::mutex> lock(model.progressMutex);
    if (stage == model.lastStage && fraction >= 0.0 && model.lastFraction >= 0.0 &&
        std::fabs(fraction - model.lastFraction) < 0.01) {
        return;
    }
    model.lastStage = stage;
    model.lastFraction = fraction;
    model.progressCallback(model.progressContext, stage, fraction, count);
}

// Adapts OCCT's progress reporting (STEP transfer, BRepMesh) to reportProgress.
class BridgeProgressIndicator : public Message_ProgressIndicator {
public:
    BridgeProgressIndicator(CADBridgeModel& model, CADLoadStage stage, uint32_t count)
        : model_(model), stage_(stage), count_(count) {}

    void Show(const Message_ProgressScope&, const Standard_Boolean) override {
        reportProgress(model_, stage_, GetPosition(), count_);
    }

    Standard_Boolean UserBreak() override { return Standard_False; }

private:
    CADBridgeModel& model_;
    CADLoadStage stage_;
    uint32_t count_;
};

// STEP/IGES translation consults process-global OCCT resource/configuration
// state. Quick Look may issue multiple thumbnail requests concurrently, so keep
// the translation stage serialized while allowing tessellation/rendering to run
// independently after import.
std::mutex importMutex;

CADPoint3D point(const gp_Pnt& value) {
    return {value.X(), value.Y(), value.Z()};
}

void clearModel(CADBridgeModel& model) {
    model.shape.Nullify();
    model.faces.clear();
    model.edgeShapes.clear();
    model.vertices.clear();
    model.triangles.clear();
    model.faceRanges.clear();
    model.polylinePoints.clear();
    model.edges.clear();
    model.bounds = {};
    model.stats = {};
    model.error.clear();
}

CADBridgeStatus fail(CADBridgeModel& model, CADBridgeStatus status, std::string message) {
    model.error = std::move(message);
    return status;
}

std::string lowercaseExtension(const std::filesystem::path& path) {
    std::string result = path.extension().string();
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return result;
}

bool importShape(CADBridgeModel& model,
                 const std::filesystem::path& path,
                 const CADMeshOptions& options,
                 TopoDS_Shape& shape,
                 std::string& error) {
    const std::string extension = lowercaseExtension(path);
    const std::string nativePath = path.string();
    reportProgress(model, CADLoadStageReading, -1.0);

    if (extension == ".step" || extension == ".stp") {
        // Use XDE for STEP so assembly instances and their nested placements
        // survive translation. The basic STEPControl reader is sufficient for
        // single parts, but can flatten product structure too early.
        STEPCAFControl_Reader reader;
        if (!options.healShapes) {
            // No ShapeProcess operations (FixShape, SplitAngle, ...): the
            // geometry is used as exported.
            reader.SetShapeProcessFlags(ShapeProcess::OperationsFlags());
        }
        if (reader.ReadFile(nativePath.c_str()) != IFSelect_RetDone) {
            error = "Open CASCADE could not parse the STEP file.";
            return false;
        }
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageTranslating, 0);
        if (!reader.Transfer(document, progress->Start())) {
            error = "The STEP file did not contain any transferable shapes.";
            return false;
        }
        const Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        TDF_LabelSequence freeShapes;
        shapeTool->GetFreeShapes(freeShapes);
        shape = XCAFDoc_ShapeTool::GetOneShape(freeShapes);
        if (shape.IsNull()) {
            // Keep a compatibility path for unusual STEP files that transfer
            // geometry but do not expose a conventional XDE free-shape label.
            shape = reader.Reader().OneShape();
        }
    } else if (extension == ".iges" || extension == ".igs") {
        IGESControl_Reader reader;
        if (reader.ReadFile(nativePath.c_str()) != IFSelect_RetDone) {
            error = "Open CASCADE could not parse the IGES file.";
            return false;
        }
        Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageTranslating, 0);
        if (reader.TransferRoots(progress->Start()) <= 0) {
            error = "The IGES file did not contain any transferable shapes.";
            return false;
        }
        shape = reader.OneShape();
    } else if (extension == ".brep" || extension == ".rle") {
        BRep_Builder builder;
        if (!BRepTools::Read(shape, nativePath.c_str(), builder)) {
            error = "Open CASCADE could not parse the BREP file.";
            return false;
        }
    } else {
        error = (extension == ".x_t" || extension == ".x_b" || extension == ".xmt_txt" || extension == ".xmt_bin")
            ? "Parasolid import requires a separately licensed Parasolid or commercial translation SDK."
            : "Unsupported CAD format. Supported extensions are STEP/STP, IGES/IGS, BREP, and STL.";
        return false;
    }

    if (shape.IsNull()) {
        error = "The imported file produced an empty shape.";
        return false;
    }
    return true;
}

CADBounds computeBounds(const TopoDS_Shape& shape) {
    CADBounds result{};
    Bnd_Box box;
    // Pole/control-point bounds: slightly loose but ~1000x cheaper than
    // AddOptimal on NURBS-heavy assemblies. Tightened from the mesh later.
    BRepBndLib::Add(shape, box, Standard_False);
    if (box.IsVoid()) {
        return result;
    }

    Standard_Real minX, minY, minZ, maxX, maxY, maxZ;
    box.Get(minX, minY, minZ, maxX, maxY, maxZ);
    result.minimum = {minX, minY, minZ};
    result.maximum = {maxX, maxY, maxZ};
    result.isValid = 1;
    return result;
}

double boundsDiagonal(const CADBounds& bounds) {
    if (!bounds.isValid) return 1.0;
    const double dx = bounds.maximum.x - bounds.minimum.x;
    const double dy = bounds.maximum.y - bounds.minimum.y;
    const double dz = bounds.maximum.z - bounds.minimum.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

double exactFaceArea(const TopoDS_Face& face) {
    GProp_GProps properties;
    BRepGProp::SurfaceProperties(face, properties, Standard_True, Standard_False);
    return properties.Mass();
}

void buildMesh(CADBridgeModel& model) {
    model.vertices.clear();
    model.triangles.clear();
    model.faceRanges.clear();
    model.faces.clear();

    for (TopExp_Explorer explorer(model.shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        model.faces.push_back(TopoDS::Face(explorer.Current()));
    }
    model.faceRanges.reserve(model.faces.size());

    // Reserve once. Calling reserve(size() + n) per face defeats the vector's
    // geometric growth and reallocates + copies the whole buffer for every
    // face, which is quadratic in the number of faces.
    {
        size_t nodeTotal = 0;
        size_t triangleTotal = 0;
        for (const TopoDS_Face& face : model.faces) {
            TopLoc_Location location;
            Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
            if (triangulation.IsNull()) continue;
            nodeTotal += static_cast<size_t>(triangulation->NbNodes());
            triangleTotal += static_cast<size_t>(triangulation->NbTriangles());
        }
        model.vertices.reserve(nodeTotal);
        model.triangles.reserve(triangleTotal);
    }

    const size_t faceReportStep = std::max<size_t>(1, model.faces.size() / 50);
    for (size_t faceIndex = 0; faceIndex < model.faces.size(); ++faceIndex) {
        if (faceIndex % faceReportStep == 0) {
            reportProgress(model, CADLoadStageBuildingMesh,
                           static_cast<double>(faceIndex) / std::max<size_t>(1, model.faces.size()),
                           static_cast<uint32_t>(model.faces.size()));
        }
        const TopoDS_Face& face = model.faces[faceIndex];
        CADFaceRange range{
            static_cast<uint32_t>(model.triangles.size()),
            0,
            -1.0 // exact area is computed on demand (CADBridgeModelFaceArea)
        };
        TopLoc_Location location;
        Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
        if (triangulation.IsNull() || triangulation->NbNodes() == 0) {
            model.faceRanges.push_back(range);
            continue;
        }

        BRepLib_ToolTriangulatedShape::ComputeNormals(face, triangulation);
        const uint32_t vertexBase = static_cast<uint32_t>(model.vertices.size());
        const gp_Trsf transformation = location.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;

        for (Standard_Integer node = 1; node <= triangulation->NbNodes(); ++node) {
            gp_Pnt position = triangulation->Node(node);
            position.Transform(transformation);

            gp_Dir normal(0.0, 0.0, 1.0);
            if (triangulation->HasNormals()) {
                normal = triangulation->Normal(node);
                normal.Transform(transformation);
                if (reversed) normal.Reverse();
            }
            model.vertices.push_back({
                static_cast<float>(position.X()), static_cast<float>(position.Y()), static_cast<float>(position.Z()),
                static_cast<float>(normal.X()), static_cast<float>(normal.Y()), static_cast<float>(normal.Z())
            });
        }

        for (Standard_Integer triangleIndex = 1; triangleIndex <= triangulation->NbTriangles(); ++triangleIndex) {
            Standard_Integer a, b, c;
            triangulation->Triangle(triangleIndex).Get(a, b, c);
            if (reversed) std::swap(b, c);
            model.triangles.push_back({
                vertexBase + static_cast<uint32_t>(a - 1),
                vertexBase + static_cast<uint32_t>(b - 1),
                vertexBase + static_cast<uint32_t>(c - 1),
                static_cast<uint32_t>(faceIndex)
            });
        }
        range.triangleCount = static_cast<uint32_t>(model.triangles.size()) - range.firstTriangle;
        model.faceRanges.push_back(range);
    }
}

double exactEdgeLength(const TopoDS_Edge& edge) {
    GProp_GProps properties;
    BRepGProp::LinearProperties(edge, properties, Standard_True, Standard_False);
    return properties.Mass();
}

void exactCircularEdgeMetadata(const TopoDS_Edge& edge,
                               uint8_t& isCircular,
                               double& exactDiameter) {
    isCircular = 0;
    exactDiameter = 0.0;
    try {
        const BRepAdaptor_Curve curve(edge);
        if (curve.GetType() == GeomAbs_Circle) {
            isCircular = 1;
            exactDiameter = curve.Circle().Radius() * 2.0;
        }
    } catch (const Standard_Failure&) {
        // Some degenerate edges do not expose an adaptable 3D curve. They are
        // valid topology, but intentionally remain non-circular metadata-wise.
    }
}

void appendEdgeSamples(const TopoDS_Edge& edge, double deflection, std::vector<CADPoint3D>& points) {
    const size_t initialSize = points.size();
    try {
        BRepAdaptor_Curve curve(edge);
        const Standard_Real first = curve.FirstParameter();
        const Standard_Real last = curve.LastParameter();
        if (!std::isfinite(first) || !std::isfinite(last)) return;

        GCPnts_QuasiUniformDeflection sampler(curve, deflection, first, last);
        if (sampler.IsDone() && sampler.NbPoints() >= 2) {
            for (Standard_Integer index = 1; index <= sampler.NbPoints(); ++index) {
                points.push_back(point(sampler.Value(index)));
            }
        }

        // Straight lines and very short curves occasionally produce no adaptive
        // samples. Preserve pickability with exact curve endpoints.
        if (points.size() == initialSize) {
            points.push_back(point(curve.Value(first)));
            const gp_Pnt endpoint = curve.Value(last);
            if (endpoint.Distance(curve.Value(first)) > Precision::Confusion()) {
                points.push_back(point(endpoint));
            }
        }
    } catch (const Standard_Failure&) {
        points.resize(initialSize);
    }
}

/// Whether the faces on either side of `edge` meet smoothly (G1) along it.
uint8_t isTangentEdge(const TopoDS_Edge& edge, const TopTools_ListOfShape* faces) {
    if (!faces || faces->Extent() < 1 || faces->Extent() > 2) return 0;
    const TopoDS_Face faceA = TopoDS::Face(faces->First());
    const TopoDS_Face faceB = TopoDS::Face(faces->Last());
    if (faces->Extent() == 1 || faceA.IsSame(faceB)) {
        // A seam: one periodic surface (cylinder, torus...) wraps round to
        // meet itself. Smooth by construction; a free boundary edge is not.
        return (faces->Extent() == 2 || BRep_Tool::IsClosed(edge, faceA)) ? 1 : 0;
    }
    try {
        Standard_Real firstA, lastA, firstB, lastB;
        const Handle(Geom2d_Curve) pcurveA = BRep_Tool::CurveOnSurface(edge, faceA, firstA, lastA);
        const Handle(Geom2d_Curve) pcurveB = BRep_Tool::CurveOnSurface(edge, faceB, firstB, lastB);
        if (pcurveA.IsNull() || pcurveB.IsNull()) return 0;
        TopLoc_Location locationA, locationB;
        const Handle(Geom_Surface) surfaceA = BRep_Tool::Surface(faceA, locationA);
        const Handle(Geom_Surface) surfaceB = BRep_Tool::Surface(faceB, locationB);
        if (surfaceA.IsNull() || surfaceB.IsNull()) return 0;

        // Normals within 1.5° at three points along the edge count as tangent.
        const double threshold = std::cos(1.5 * M_PI / 180.0);
        for (const double t : {0.15, 0.5, 0.85}) {
            const gp_Pnt2d uvA = pcurveA->Value(firstA + t * (lastA - firstA));
            const gp_Pnt2d uvB = pcurveB->Value(firstB + t * (lastB - firstB));
            GeomLProp_SLProps propsA(surfaceA, uvA.X(), uvA.Y(), 1, Precision::Confusion());
            GeomLProp_SLProps propsB(surfaceB, uvB.X(), uvB.Y(), 1, Precision::Confusion());
            if (!propsA.IsNormalDefined() || !propsB.IsNormalDefined()) return 0;
            gp_Dir normalA = propsA.Normal();
            gp_Dir normalB = propsB.Normal();
            normalA.Transform(locationA.Transformation());
            normalB.Transform(locationB.Transformation());
            // Compare outward normals, so the front and back of a sheet body
            // (anti-parallel) stay a sharp boundary.
            if (faceA.Orientation() == TopAbs_REVERSED) normalA.Reverse();
            if (faceB.Orientation() == TopAbs_REVERSED) normalB.Reverse();
            if (normalA.Dot(normalB) < threshold) return 0;
        }
        return 1;
    } catch (const Standard_Failure&) {
        return 0;
    }
}

void buildEdges(CADBridgeModel& model, double edgeDeflection) {
    model.edges.clear();
    model.edgeShapes.clear();
    model.polylinePoints.clear();

    TopTools_IndexedMapOfShape edgeMap;
    TopExp::MapShapes(model.shape, TopAbs_EDGE, edgeMap);
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(model.shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    model.edges.reserve(static_cast<size_t>(edgeMap.Extent()));
    model.edgeShapes.reserve(static_cast<size_t>(edgeMap.Extent()));

    const Standard_Integer edgeReportStep = std::max(1, edgeMap.Extent() / 50);
    for (Standard_Integer index = 1; index <= edgeMap.Extent(); ++index) {
        if (index % edgeReportStep == 0) {
            reportProgress(model, CADLoadStageSamplingEdges,
                           static_cast<double>(index) / std::max(1, edgeMap.Extent()),
                           static_cast<uint32_t>(edgeMap.Extent()));
        }
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(index));
        model.edgeShapes.push_back(edge);
        const uint32_t firstPoint = static_cast<uint32_t>(model.polylinePoints.size());
        appendEdgeSamples(edge, edgeDeflection, model.polylinePoints);
        const uint32_t pointCount = static_cast<uint32_t>(model.polylinePoints.size()) - firstPoint;
        uint8_t isCircular = 0;
        double exactDiameter = 0.0;
        exactCircularEdgeMetadata(edge, isCircular, exactDiameter);
        const TopTools_ListOfShape* faces = edgeFaces.Contains(edge) ? &edgeFaces.FindFromKey(edge) : nullptr;
        model.edges.push_back({
            firstPoint,
            pointCount,
            -1.0, // exact length is computed on demand (CADBridgeModelEdgeLength)
            isCircular,
            exactDiameter,
            isTangentEdge(edge, faces)
        });
    }
}

/// Loads an STL as a bare mesh: one display "face" holding every triangle,
/// no B-Rep and no edges. Going through StlAPI_Reader instead would build a
/// B-Rep face per triangle, which takes minutes on scan data and crashes
/// inside BRepLib_MakeFace on degenerate triangles.
bool loadStlMesh(CADBridgeModel& model, const std::filesystem::path& path, std::string& error) {
    Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageReading, 0);
    // Nodes are shared only across gentle (<30°) angles, so smoothed normals
    // do not soften the sharp edges of machined parts.
    const Handle(Poly_Triangulation) mesh = RWStl::ReadFile(path.c_str(), 30.0 * M_PI / 180.0, progress->Start());
    if (mesh.IsNull() || mesh->NbTriangles() == 0 || mesh->NbNodes() == 0) {
        error = "Open CASCADE could not parse the STL file.";
        return false;
    }
    const uint32_t triangleCount = static_cast<uint32_t>(mesh->NbTriangles());
    reportProgress(model, CADLoadStageBuildingMesh, -1.0, triangleCount);
    mesh->ComputeNormals();

    model.vertices.reserve(static_cast<size_t>(mesh->NbNodes()));
    for (Standard_Integer node = 1; node <= mesh->NbNodes(); ++node) {
        const gp_Pnt position = mesh->Node(node);
        gp_Vec3f raw(0.0f, 0.0f, 1.0f);
        if (mesh->HasNormals()) mesh->Normal(node, raw);
        // Nodes used only by collinear triangles get a zero normal; gp_Dir would throw.
        const float modulus = raw.Modulus();
        const gp_Vec3f normal = modulus > 0.0f ? raw / modulus : gp_Vec3f(0.0f, 0.0f, 1.0f);
        model.vertices.push_back({
            static_cast<float>(position.X()), static_cast<float>(position.Y()), static_cast<float>(position.Z()),
            normal.x(), normal.y(), normal.z()
        });
    }

    double area = 0.0;
    model.triangles.reserve(triangleCount);
    for (Standard_Integer index = 1; index <= mesh->NbTriangles(); ++index) {
        Standard_Integer a, b, c;
        mesh->Triangle(index).Get(a, b, c);
        if (a == b || b == c || a == c) continue;
        const gp_XYZ ab = mesh->Node(b).XYZ() - mesh->Node(a).XYZ();
        const gp_XYZ ac = mesh->Node(c).XYZ() - mesh->Node(a).XYZ();
        area += ab.Crossed(ac).Modulus() * 0.5;
        model.triangles.push_back({
            static_cast<uint32_t>(a - 1), static_cast<uint32_t>(b - 1), static_cast<uint32_t>(c - 1), 0
        });
    }
    if (model.triangles.empty()) {
        error = "The STL file did not contain any display triangles.";
        return false;
    }
    model.faceRanges.push_back({0, static_cast<uint32_t>(model.triangles.size()), area});
    return true;
}

/// Shrinks the bounds to the display mesh (B-Rep bounds are pole-loose).
void tightenBounds(CADBridgeModel& model) {
    if (model.vertices.empty()) return;
    CADBounds tight{};
    tight.minimum = {model.vertices[0].x, model.vertices[0].y, model.vertices[0].z};
    tight.maximum = tight.minimum;
    for (const CADVertex& v : model.vertices) {
        tight.minimum.x = std::min(tight.minimum.x, static_cast<double>(v.x));
        tight.minimum.y = std::min(tight.minimum.y, static_cast<double>(v.y));
        tight.minimum.z = std::min(tight.minimum.z, static_cast<double>(v.z));
        tight.maximum.x = std::max(tight.maximum.x, static_cast<double>(v.x));
        tight.maximum.y = std::max(tight.maximum.y, static_cast<double>(v.y));
        tight.maximum.z = std::max(tight.maximum.z, static_cast<double>(v.z));
    }
    tight.isValid = 1;
    model.bounds = tight;
}

uint32_t countSubshapes(const TopoDS_Shape& shape, TopAbs_ShapeEnum type) {
    if (shape.IsNull()) return 0;
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, type, map);
    return static_cast<uint32_t>(map.Extent());
}

CADModelStats computeStats(const CADBridgeModel& model) {
    CADModelStats stats{};
    stats.faceCount = static_cast<uint32_t>(model.faceRanges.size());
    stats.edgeCount = static_cast<uint32_t>(model.edges.size());
    stats.vertexCount = model.shape.IsNull()
        ? static_cast<uint32_t>(model.vertices.size()) : countSubshapes(model.shape, TopAbs_VERTEX);
    stats.shellCount = model.shape.IsNull() ? 1 : countSubshapes(model.shape, TopAbs_SHELL);
    stats.solidCount = countSubshapes(model.shape, TopAbs_SOLID);
    stats.triangleCount = static_cast<uint32_t>(model.triangles.size());
    // Total edge length, surface area and volume are not displayed anywhere
    // and cost seconds on large assemblies; left at zero.
    return stats;
}

} // namespace

CADMeshOptions CADBridgeDefaultMeshOptions(void) {
    return {0.0, 0.15, 0.0, 1, 1.0, 1};
}

CADBridgeModel *CADBridgeModelCreate(void) {
    try {
        return new CADBridgeModel();
    } catch (...) {
        return nullptr;
    }
}

void CADBridgeModelDestroy(CADBridgeModel *model) {
    delete model;
}

CADBridgeStatus CADBridgeModelLoad(CADBridgeModel *model, const char *pathUTF8, CADMeshOptions options) {
    if (!model || !pathUTF8 || pathUTF8[0] == '\0') {
        if (model) model->error = "A non-empty UTF-8 file path is required.";
        return CADBridgeStatusInvalidArgument;
    }

    clearModel(*model);
    try {
        // macOS's native narrow filesystem representation is UTF-8.
        const std::filesystem::path path(pathUTF8);
        std::error_code filesystemError;
        if (!std::filesystem::is_regular_file(path, filesystemError)) {
            return fail(*model, CADBridgeStatusFileNotFound, "The CAD file does not exist or is not a regular file.");
        }

        if (lowercaseExtension(path) == ".stl") {
            std::string meshError;
            if (!loadStlMesh(*model, path, meshError)) {
                return fail(*model, CADBridgeStatusImportFailed, std::move(meshError));
            }
            tightenBounds(*model);
            reportProgress(*model, CADLoadStageFinishing, -1.0);
            model->stats = computeStats(*model);
            return CADBridgeStatusOK;
        }

        std::string importError;
        bool imported = false;
        {
            std::lock_guard<std::mutex> lock(importMutex);
            imported = importShape(*model, path, options, model->shape, importError);
        }
        if (!imported) {
            const std::string extension = lowercaseExtension(path);
            const bool unsupported = extension != ".step" && extension != ".stp" &&
                                     extension != ".iges" && extension != ".igs" &&
                                     extension != ".brep" && extension != ".rle";
            return fail(*model, unsupported ? CADBridgeStatusUnsupportedFormat : CADBridgeStatusImportFailed,
                        std::move(importError));
        }

        model->bounds = computeBounds(model->shape);
        const double diagonal = std::max(boundsDiagonal(model->bounds), 1.0e-6);
        // Large assemblies (thousands of faces) are viewed as a whole, so
        // they can use a coarser mesh than a single part without looking worse.
        const double faceCount = static_cast<double>(countSubshapes(model->shape, TopAbs_FACE));
        const double complexity = std::clamp(faceCount / 2000.0, 1.0, 4.0);
        const double deflectionScale = (options.linearDeflectionScale > 0.0 ? options.linearDeflectionScale : 1.0) * complexity;
        const double linearDeflection = options.linearDeflection > 0.0
            ? options.linearDeflection : std::max(diagonal * 0.0004 * deflectionScale, 1.0e-6);
        const double angularDeflection = options.angularDeflectionRadians > 0.0
            ? options.angularDeflectionRadians : std::min(0.15 * complexity, 0.35);
        const double edgeDeflection = options.edgeDeflection > 0.0
            ? options.edgeDeflection : linearDeflection;

        IMeshTools_Parameters meshParameters;
        meshParameters.Deflection = linearDeflection;
        meshParameters.Angle = angularDeflection;
        meshParameters.Relative = Standard_False;
        meshParameters.InParallel = options.parallel ? Standard_True : Standard_False;
        Handle(BridgeProgressIndicator) meshProgress =
            new BridgeProgressIndicator(*model, CADLoadStageMeshing, static_cast<uint32_t>(faceCount));
        BRepMesh_IncrementalMesh mesher(model->shape, meshParameters, meshProgress->Start());
        if (!mesher.IsDone()) {
            return fail(*model, CADBridgeStatusMeshingFailed, "Open CASCADE could not tessellate the imported shape.");
        }

        buildMesh(*model);
        buildEdges(*model, edgeDeflection);
        tightenBounds(*model);
        reportProgress(*model, CADLoadStageFinishing, -1.0);
        model->stats = computeStats(*model);
        if (model->triangles.empty()) {
            return fail(*model, CADBridgeStatusMeshingFailed, "The imported shape did not produce any display triangles.");
        }
        return CADBridgeStatusOK;
    } catch (const Standard_Failure& exception) {
        return fail(*model, CADBridgeStatusInternalError,
                    std::string("Open CASCADE error: ") + exception.GetMessageString());
    } catch (const std::exception& exception) {
        return fail(*model, CADBridgeStatusInternalError,
                    std::string("CAD bridge error: ") + exception.what());
    } catch (...) {
        return fail(*model, CADBridgeStatusInternalError, "Unknown CAD bridge error.");
    }
}

const char *CADBridgeModelLastError(const CADBridgeModel *model) {
    return model ? model->error.c_str() : "CAD model is null.";
}

const CADVertex *CADBridgeModelVertices(const CADBridgeModel *model) {
    return model && !model->vertices.empty() ? model->vertices.data() : nullptr;
}

size_t CADBridgeModelVertexCount(const CADBridgeModel *model) {
    return model ? model->vertices.size() : 0;
}

const CADTriangle *CADBridgeModelTriangles(const CADBridgeModel *model) {
    return model && !model->triangles.empty() ? model->triangles.data() : nullptr;
}

size_t CADBridgeModelTriangleCount(const CADBridgeModel *model) {
    return model ? model->triangles.size() : 0;
}

const CADFaceRange *CADBridgeModelFaceRanges(const CADBridgeModel *model) {
    return model && !model->faceRanges.empty() ? model->faceRanges.data() : nullptr;
}

size_t CADBridgeModelFaceCount(const CADBridgeModel *model) {
    return model ? model->faceRanges.size() : 0;
}

const CADPoint3D *CADBridgeModelPolylinePoints(const CADBridgeModel *model) {
    return model && !model->polylinePoints.empty() ? model->polylinePoints.data() : nullptr;
}

size_t CADBridgeModelPolylinePointCount(const CADBridgeModel *model) {
    return model ? model->polylinePoints.size() : 0;
}

const CADEdgePolyline *CADBridgeModelEdges(const CADBridgeModel *model) {
    return model && !model->edges.empty() ? model->edges.data() : nullptr;
}

size_t CADBridgeModelEdgeCount(const CADBridgeModel *model) {
    return model ? model->edges.size() : 0;
}

CADBounds CADBridgeModelBounds(const CADBridgeModel *model) {
    return model ? model->bounds : CADBounds{};
}

CADModelStats CADBridgeModelStats(const CADBridgeModel *model) {
    return model ? model->stats : CADModelStats{};
}

void CADBridgeModelSetProgressCallback(CADBridgeModel *model, CADBridgeProgressCallback callback, void *context) {
    if (!model) return;
    std::lock_guard<std::mutex> lock(model->progressMutex);
    model->progressCallback = callback;
    model->progressContext = context;
    model->lastFraction = -2.0;
}

CADBridgeStatus CADBridgeModelFaceArea(CADBridgeModel *model, uint32_t faceIndex, double *outArea) {
    if (!model || !outArea) return CADBridgeStatusInvalidArgument;
    if (faceIndex >= model->faceRanges.size()) return CADBridgeStatusOutOfRange;
    CADFaceRange& range = model->faceRanges[faceIndex];
    if (range.exactArea < 0.0) {
        try {
            // Mesh-only models (STL) have no B-Rep face; their area was
            // summed from the triangles at load time.
            range.exactArea = faceIndex < model->faces.size() ? exactFaceArea(model->faces[faceIndex]) : 0.0;
        } catch (const Standard_Failure&) {
            range.exactArea = 0.0;
        }
    }
    *outArea = range.exactArea;
    return CADBridgeStatusOK;
}

CADBridgeStatus CADBridgeModelEdgeLength(CADBridgeModel *model, uint32_t edgeIndex, double *outLength) {
    if (!model || !outLength) return CADBridgeStatusInvalidArgument;
    if (edgeIndex >= model->edgeShapes.size()) return CADBridgeStatusOutOfRange;
    CADEdgePolyline& edge = model->edges[edgeIndex];
    if (edge.exactLength < 0.0) {
        try {
            edge.exactLength = exactEdgeLength(model->edgeShapes[edgeIndex]);
        } catch (const Standard_Failure&) {
            edge.exactLength = 0.0;
        }
    }
    *outLength = edge.exactLength;
    return CADBridgeStatusOK;
}

CADBridgeStatus CADBridgeModelMeasureFaceDistance(CADBridgeModel *model,
                                                  uint32_t faceA,
                                                  uint32_t faceB,
                                                  CADFaceDistance *result) {
    if (!model || !result) {
        if (model) model->error = "A model and output measurement are required.";
        return CADBridgeStatusInvalidArgument;
    }
    if (faceA >= model->faces.size() || faceB >= model->faces.size()) {
        return fail(*model, CADBridgeStatusOutOfRange, "Face index is out of range.");
    }

    try {
        BRepExtrema_DistShapeShape distance(model->faces[faceA], model->faces[faceB]);
        if (!distance.IsDone() || distance.NbSolution() < 1) {
            return fail(*model, CADBridgeStatusMeasurementFailed,
                        "Open CASCADE could not compute the minimum face distance.");
        }
        result->distance = distance.Value();
        result->pointOnFaceA = point(distance.PointOnShape1(1));
        result->pointOnFaceB = point(distance.PointOnShape2(1));
        model->error.clear();
        return CADBridgeStatusOK;
    } catch (const Standard_Failure& exception) {
        return fail(*model, CADBridgeStatusMeasurementFailed,
                    std::string("Open CASCADE measurement error: ") + exception.GetMessageString());
    } catch (const std::exception& exception) {
        return fail(*model, CADBridgeStatusMeasurementFailed,
                    std::string("CAD measurement error: ") + exception.what());
    } catch (...) {
        return fail(*model, CADBridgeStatusMeasurementFailed, "Unknown face measurement error.");
    }
}
