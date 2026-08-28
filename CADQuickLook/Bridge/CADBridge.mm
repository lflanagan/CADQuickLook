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
#include <IGESControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <StlAPI_Reader.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
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
    std::vector<CADVertex> vertices;
    std::vector<CADTriangle> triangles;
    std::vector<CADFaceRange> faceRanges;
    std::vector<CADPoint3D> polylinePoints;
    std::vector<CADEdgePolyline> edges;
    CADBounds bounds{};
    CADModelStats stats{};
    std::string error;
};

namespace {

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

bool importShape(const std::filesystem::path& path, TopoDS_Shape& shape, std::string& error) {
    const std::string extension = lowercaseExtension(path);
    const std::string nativePath = path.string();

    if (extension == ".step" || extension == ".stp") {
        // Use XDE for STEP so assembly instances and their nested placements
        // survive translation. The basic STEPControl reader is sufficient for
        // single parts, but can flatten product structure too early.
        STEPCAFControl_Reader reader;
        if (reader.ReadFile(nativePath.c_str()) != IFSelect_RetDone) {
            error = "Open CASCADE could not parse the STEP file.";
            return false;
        }
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        if (!reader.Transfer(document)) {
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
        if (reader.TransferRoots() <= 0) {
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
    } else if (extension == ".stl") {
        StlAPI_Reader reader;
        if (!reader.Read(shape, nativePath.c_str())) {
            error = "Open CASCADE could not parse the STL file.";
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
    BRepBndLib::AddOptimal(shape, box, Standard_False, Standard_False);
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

    for (size_t faceIndex = 0; faceIndex < model.faces.size(); ++faceIndex) {
        const TopoDS_Face& face = model.faces[faceIndex];
        CADFaceRange range{
            static_cast<uint32_t>(model.triangles.size()),
            0,
            exactFaceArea(face)
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

        model.vertices.reserve(model.vertices.size() + static_cast<size_t>(triangulation->NbNodes()));
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

        model.triangles.reserve(model.triangles.size() + static_cast<size_t>(triangulation->NbTriangles()));
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

void buildEdges(CADBridgeModel& model, double edgeDeflection) {
    model.edges.clear();
    model.polylinePoints.clear();

    TopTools_IndexedMapOfShape edgeMap;
    TopExp::MapShapes(model.shape, TopAbs_EDGE, edgeMap);
    model.edges.reserve(static_cast<size_t>(edgeMap.Extent()));

    for (Standard_Integer index = 1; index <= edgeMap.Extent(); ++index) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(index));
        const uint32_t firstPoint = static_cast<uint32_t>(model.polylinePoints.size());
        appendEdgeSamples(edge, edgeDeflection, model.polylinePoints);
        const uint32_t pointCount = static_cast<uint32_t>(model.polylinePoints.size()) - firstPoint;
        uint8_t isCircular = 0;
        double exactDiameter = 0.0;
        exactCircularEdgeMetadata(edge, isCircular, exactDiameter);
        model.edges.push_back({
            firstPoint,
            pointCount,
            exactEdgeLength(edge),
            isCircular,
            exactDiameter
        });
    }
}

uint32_t countSubshapes(const TopoDS_Shape& shape, TopAbs_ShapeEnum type) {
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, type, map);
    return static_cast<uint32_t>(map.Extent());
}

CADModelStats computeStats(const CADBridgeModel& model) {
    CADModelStats stats{};
    stats.faceCount = static_cast<uint32_t>(model.faces.size());
    stats.edgeCount = static_cast<uint32_t>(model.edges.size());
    stats.vertexCount = countSubshapes(model.shape, TopAbs_VERTEX);
    stats.shellCount = countSubshapes(model.shape, TopAbs_SHELL);
    stats.solidCount = countSubshapes(model.shape, TopAbs_SOLID);
    stats.triangleCount = static_cast<uint32_t>(model.triangles.size());
    for (const CADEdgePolyline& edge : model.edges) stats.totalEdgeLength += edge.exactLength;

    GProp_GProps surfaceProperties;
    BRepGProp::SurfaceProperties(model.shape, surfaceProperties, Standard_True, Standard_False);
    stats.surfaceArea = surfaceProperties.Mass();
    GProp_GProps volumeProperties;
    BRepGProp::VolumeProperties(model.shape, volumeProperties, Standard_True, Standard_False, Standard_False);
    stats.volume = volumeProperties.Mass();
    return stats;
}

} // namespace

CADMeshOptions CADBridgeDefaultMeshOptions(void) {
    return {0.0, 0.35, 0.0, 1};
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

        std::string importError;
        bool imported = false;
        {
            std::lock_guard<std::mutex> lock(importMutex);
            imported = importShape(path, model->shape, importError);
        }
        if (!imported) {
            const std::string extension = lowercaseExtension(path);
            const bool unsupported = extension != ".step" && extension != ".stp" &&
                                     extension != ".iges" && extension != ".igs" &&
                                     extension != ".brep" && extension != ".rle" && extension != ".stl";
            return fail(*model, unsupported ? CADBridgeStatusUnsupportedFormat : CADBridgeStatusImportFailed,
                        std::move(importError));
        }

        model->bounds = computeBounds(model->shape);
        const double diagonal = std::max(boundsDiagonal(model->bounds), 1.0e-6);
        const double linearDeflection = options.linearDeflection > 0.0
            ? options.linearDeflection : std::max(diagonal * 0.001, 1.0e-6);
        const double angularDeflection = options.angularDeflectionRadians > 0.0
            ? options.angularDeflectionRadians : 0.35;
        const double edgeDeflection = options.edgeDeflection > 0.0
            ? options.edgeDeflection : linearDeflection;

        BRepMesh_IncrementalMesh mesher(model->shape,
                                        linearDeflection,
                                        Standard_False,
                                        angularDeflection,
                                        options.parallel ? Standard_True : Standard_False);
        if (!mesher.IsDone()) {
            return fail(*model, CADBridgeStatusMeshingFailed, "Open CASCADE could not tessellate the imported shape.");
        }

        buildMesh(*model);
        buildEdges(*model, edgeDeflection);
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
