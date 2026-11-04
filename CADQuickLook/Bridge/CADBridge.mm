#include "CADBridge.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBndLib.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BinTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomConvert_CurveToAnaCurve.hxx>
#include <GeomConvert_SurfToAnaSurf.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom_Circle.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Line.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <Geom_Surface.hxx>
#include <IGESControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <ShapeProcess.hxx>
#include <DE_ShapeFixParameters.hxx>
#include <NCollection_Map.hxx>
#include <OSD_Parallel.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TopoDS_Compound.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <IMeshTools_Parameters.hxx>
#include <STEPControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <RWStl.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFApp_Application.hxx>
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
#include <Quantity_Color.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Circ.hxx>
#include <gp_Cone.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Dir.hxx>
#include <gp_Lin.hxx>
#include <gp_Pln.hxx>
#include <gp_Sphere.hxx>
#include <gp_Torus.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_XYZ.hxx>

#include <mach/mach.h>
#include <malloc/malloc.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cctype>
#include <filesystem>
#include <istream>
#include <ostream>
#include <streambuf>
#include <limits>
#include <mutex>
#include <array>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

struct CADBridgeCancelToken {
    std::atomic<int> refs{1};
    std::atomic<bool> cancelled{false};
    /// phys_footprint above which a load stops; 0 = no budget.
    uint64_t memoryBudget = 0;
};

namespace {

/// Why a load stopped early. The first reason recorded wins.
enum class AbortReason : int {
    none = 0,
    cancelled,
    memory,
    tooManyFaces,
    tooManyTriangles,
    tooManyEdges,
    tooManyPoints,
};

} // namespace

struct CADBridgeModel {
    ~CADBridgeModel() {
        if (cancelToken) CADBridgeCancelTokenRelease(cancelToken);
    }

    TopoDS_Shape shape;
    /// STEP colours keyed by face TShape, gathered from the XDE document at
    /// import and applied to CADFaceRange in buildMesh.
    std::unordered_map<const TopoDS_TShape*, std::array<float, 3>> faceColors;
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

    /// Token installed by CADBridgeModelSetCancelToken (retained).
    std::mutex tokenMutex;
    CADBridgeCancelToken *cancelToken = nullptr;
    /// The token of the load in progress, retained for the whole load so a
    /// concurrent SetCancelToken cannot free it under the worker threads.
    CADBridgeCancelToken *activeToken = nullptr;
    /// First AbortReason recorded during the current load (read and written
    /// from OCCT worker threads through UserBreak).
    std::atomic<int> abortReason{0};
    std::atomic<uint32_t> abortPollCounter{0};
    /// Over-budget path only: bytes of the footprint last found to be free
    /// malloc memory, and the footprint samples left before re-measuring.
    std::atomic<uint64_t> mallocRetained{0};
    std::atomic<int> retainedSamplesLeft{0};
    /// The count that exceeded a size limit, and the limit, for the message.
    size_t limitCount = 0;
    size_t limitValue = 0;
    /// Size limits of the current load, derived from the memory budget.
    size_t maxTriangles = 0;
    size_t maxPoints = 0;
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

/// Size limits that do not depend on the memory budget. They also keep every
/// uint32 index in the display arrays far below 2^32.
constexpr size_t kMaxTriangles = 100'000'000;
constexpr size_t kMaxPoints = 100'000'000;
constexpr size_t kMaxEdges = 20'000'000;
constexpr size_t kMaxFaces = 20'000'000;
/// Approximate bytes per display triangle and per polyline point, across the
/// bridge's arrays, OCCT's triangulation and the host's copies. A budget of B
/// bytes allows B / 160 triangles and B / 96 polyline points.
constexpr uint64_t kBytesPerTriangle = 160;
constexpr uint64_t kBytesPerPoint = 96;

/// Thrown (from the loading thread only, never from OCCT callbacks or
/// OSD_Parallel workers) to unwind a load that was stopped early.
struct LoadAborted {
    CADBridgeStatus status;
    std::string message;
};

uint64_t physicalFootprint() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

/// Footprint samples between two malloc_zone_statistics calls (0.1-0.5 ms
/// each) while the footprint is over budget.
constexpr int kRetainedCacheSamples = 16;

/// The memory the load is really using, when phys_footprint is over budget.
/// malloc keeps freed pages resident (a stopped load leaves hundreds of MB of
/// "empty" large and small regions), and on macOS 27
/// malloc_zone_pressure_relief returns none of them, so the next load would
/// start over budget. Subtract malloc's free bytes, but never report less
/// than malloc's live bytes: the free figure also counts pages that are no
/// longer resident.
uint64_t budgetedFootprint(CADBridgeModel& model, uint64_t footprint) {
    if (model.retainedSamplesLeft.fetch_sub(1, std::memory_order_relaxed) <= 0) {
        malloc_statistics_t statistics{};
        malloc_zone_statistics(nullptr, &statistics);
        const uint64_t mallocFree = statistics.size_allocated > statistics.size_in_use
            ? statistics.size_allocated - statistics.size_in_use : 0;
        const uint64_t live = std::max<uint64_t>(footprint > mallocFree ? footprint - mallocFree : 0, statistics.size_in_use);
        model.mallocRetained.store(footprint - std::min(footprint, live), std::memory_order_relaxed);
        model.retainedSamplesLeft.store(kRetainedCacheSamples, std::memory_order_relaxed);
        return live;
    }
    const uint64_t retained = model.mallocRetained.load(std::memory_order_relaxed);
    return footprint > retained ? footprint - retained : 0;
}

/// Records why the load stops; the first reason wins. Thread-safe.
void recordAbort(CADBridgeModel& model, AbortReason reason) {
    int expected = static_cast<int>(AbortReason::none);
    model.abortReason.compare_exchange_strong(expected, static_cast<int>(reason), std::memory_order_relaxed);
}

/// Whether the current load should stop: it was cancelled, a size limit was
/// hit, or the process footprint is over the token's memory budget. Called
/// from OSD_Parallel worker threads (through UserBreak and the parallel
/// loops), so it only touches atomics. The footprint is sampled every 256
/// calls unless `force` is set.
bool shouldAbort(CADBridgeModel& model, bool force = false) {
    if (model.abortReason.load(std::memory_order_relaxed) != static_cast<int>(AbortReason::none)) return true;
    CADBridgeCancelToken *token = model.activeToken;
    if (!token) return false;
    if (token->cancelled.load(std::memory_order_relaxed)) {
        recordAbort(model, AbortReason::cancelled);
        return true;
    }
    if (token->memoryBudget > 0 &&
        (force || (model.abortPollCounter.fetch_add(1, std::memory_order_relaxed) & 255u) == 0)) {
        const uint64_t footprint = physicalFootprint();
        // Cheap test first; the malloc correction runs only over budget.
        if (footprint > token->memoryBudget && budgetedFootprint(model, footprint) > token->memoryBudget) {
            recordAbort(model, AbortReason::memory);
            return true;
        }
    }
    return false;
}

/// "163000000" -> "163,000,000".
std::string groupedNumber(size_t value) {
    std::string digits = std::to_string(value);
    for (int position = static_cast<int>(digits.size()) - 3; position > 0; position -= 3) {
        digits.insert(static_cast<size_t>(position), ",");
    }
    return digits;
}

LoadAborted abortError(const CADBridgeModel& model) {
    const auto reason = static_cast<AbortReason>(model.abortReason.load(std::memory_order_relaxed));
    const std::string count = groupedNumber(model.limitCount);
    const std::string limit = groupedNumber(model.limitValue);
    switch (reason) {
    case AbortReason::cancelled:
        return {CADBridgeStatusCancelled, "Loading was cancelled."};
    case AbortReason::memory: {
        const double gigabytes = model.activeToken
            ? static_cast<double>(model.activeToken->memoryBudget) / (1024.0 * 1024.0 * 1024.0) : 0.0;
        char budget[32];
        std::snprintf(budget, sizeof budget, "%.1f", gigabytes);
        return {CADBridgeStatusResourceLimit,
                std::string("Stopped loading: CADQuickLook reached its memory limit of ") + budget +
                " GB while opening this model. Close other models and try again."};
    }
    case AbortReason::tooManyFaces:
        return {CADBridgeStatusResourceLimit,
                "This model is too complex to display: it has more than " + count +
                " faces, and the limit is " + limit + "."};
    case AbortReason::tooManyTriangles:
        return {CADBridgeStatusResourceLimit,
                "This model is too complex to display: it needs " + count +
                " triangles (counting every instance of each part), and the limit is " + limit + "."};
    case AbortReason::tooManyEdges:
        return {CADBridgeStatusResourceLimit,
                "This model is too complex to display: it has " + count +
                " edges, and the limit is " + limit + "."};
    case AbortReason::tooManyPoints:
        return {CADBridgeStatusResourceLimit,
                "This model is too complex to display: drawing its edges needs more than " + count +
                " points, and the limit is " + limit + "."};
    case AbortReason::none:
        break;
    }
    return {CADBridgeStatusInternalError, "The load stopped for an unknown reason."};
}

/// Throws LoadAborted if the load should stop. Loading thread only.
void checkpoint(CADBridgeModel& model) {
    if (shouldAbort(model, true)) throw abortError(model);
}

/// Records a size-limit failure (the first reason wins). Thread-safe: only
/// the thread that records the reason writes the counts, and the loading
/// thread reads them after the parallel loop has joined.
void recordLimit(CADBridgeModel& model, AbortReason reason, size_t count, size_t limit) {
    int expected = static_cast<int>(AbortReason::none);
    if (model.abortReason.compare_exchange_strong(expected, static_cast<int>(reason), std::memory_order_relaxed)) {
        model.limitCount = count;
        model.limitValue = limit;
    }
}

/// Records a size-limit failure and throws. Loading thread only.
[[noreturn]] void abortTooComplex(CADBridgeModel& model, AbortReason reason, size_t count, size_t limit) {
    recordLimit(model, reason, count, limit);
    throw abortError(model);
}

// Adapts OCCT's progress reporting (STEP transfer, BRepMesh) to reportProgress.
class BridgeProgressIndicator : public Message_ProgressIndicator {
public:
    BridgeProgressIndicator(CADBridgeModel& model, CADLoadStage stage, uint32_t count)
        : model_(model), stage_(stage), count_(count) {}

    void Show(const Message_ProgressScope&, const Standard_Boolean) override {
        reportProgress(model_, stage_, GetPosition(), count_);
    }

    // Called from OSD_Parallel worker threads during BRepMesh.
    Standard_Boolean UserBreak() override { return shouldAbort(model_) ? Standard_True : Standard_False; }

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
    model.faceColors.clear();
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

/// clearModel, and also hands the arrays' capacity back to malloc: a load
/// that stopped early may have reserved gigabytes.
void releaseModelData(CADBridgeModel& model) {
    clearModel(model);
    decltype(model.faceColors)().swap(model.faceColors);
    std::vector<TopoDS_Face>().swap(model.faces);
    std::vector<TopoDS_Edge>().swap(model.edgeShapes);
    std::vector<CADVertex>().swap(model.vertices);
    std::vector<CADTriangle>().swap(model.triangles);
    std::vector<CADFaceRange>().swap(model.faceRanges);
    std::vector<CADPoint3D>().swap(model.polylinePoints);
    std::vector<CADEdgePolyline>().swap(model.edges);
}

CADPoint3D point(const gp_Dir& value) {
    return {value.X(), value.Y(), value.Z()};
}

/// Tolerance for recognising an analytic curve/surface hiding in a spline
/// (many exporters write cylinders and circles as NURBS). Model units are
/// millimetres, so this is a micron-scale fit on ordinary parts.
constexpr double analyticTolerance = 1.0e-3;

/// Exporters often write cylinders, cones and spheres as B-spline surfaces.
/// Try to recover the analytic surface so the viewer can report a diameter.
void recoverAnalyticSurface(const TopoDS_Face& face, bool reversed, CADFaceRange& range) {
    TopLoc_Location location;
    Handle(Geom_Surface) surface = BRep_Tool::Surface(face, location);
    // ConvertToAnalytical classifies through GeomAdaptor_Surface, which sees
    // through a trimmed surface and reports the basis's BSpline/Bezier type,
    // then down-casts the *trimmed* handle to that type and segments the null
    // result (OCCT 7.9.3, SIGSEGV in Geom_BSplineSurface::segment). Hand it
    // the basis surface instead; it shares the trim's parameterisation, so
    // the face's UV bounds still apply.
    while (Handle(Geom_RectangularTrimmedSurface) trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(surface)) {
        surface = trimmed->BasisSurface();
    }
    if (surface.IsNull()) return;
    Standard_Real umin, umax, vmin, vmax;
    BRepTools::UVBounds(face, umin, umax, vmin, vmax);
    if (!std::isfinite(umin) || !std::isfinite(umax) || !std::isfinite(vmin) || !std::isfinite(vmax)) return;
    GeomConvert_SurfToAnaSurf converter(surface);
    converter.SetConvType(GeomConvert_Simplest);
    Handle(Geom_Surface) analytic = converter.ConvertToAnalytical(analyticTolerance, umin, umax, vmin, vmax);
    if (analytic.IsNull()) return;
    // Transform a copy: the converter may hand back the face's own surface,
    // and transforming that in place would move the shared B-Rep geometry.
    analytic = Handle(Geom_Surface)::DownCast(analytic->Transformed(location.Transformation()));
    if (analytic.IsNull()) return;

    if (Handle(Geom_CylindricalSurface) cylinder = Handle(Geom_CylindricalSurface)::DownCast(analytic)) {
        range.surfaceType = CADSurfaceTypeCylinder;
        range.radius = cylinder->Radius();
        range.axisDirection = point(cylinder->Axis().Direction());
    } else if (Handle(Geom_SphericalSurface) sphere = Handle(Geom_SphericalSurface)::DownCast(analytic)) {
        range.surfaceType = CADSurfaceTypeSphere;
        range.radius = sphere->Radius();
    } else if (Handle(Geom_ConicalSurface) cone = Handle(Geom_ConicalSurface)::DownCast(analytic)) {
        range.surfaceType = CADSurfaceTypeCone;
        range.radius = cone->RefRadius();
        range.axisDirection = point(cone->Axis().Direction());
    } else if (Handle(Geom_ToroidalSurface) torus = Handle(Geom_ToroidalSurface)::DownCast(analytic)) {
        range.surfaceType = CADSurfaceTypeTorus;
        range.radius = torus->MajorRadius();
        range.axisDirection = point(torus->Axis().Direction());
    } else if (Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(analytic)) {
        gp_Dir normal = plane->Axis().Direction();
        if (!plane->Pln().Direct()) normal.Reverse();
        if (reversed) normal.Reverse();
        range.surfaceType = CADSurfaceTypePlane;
        range.axisDirection = point(normal);
    }
}

/// Fills the analytic surface metadata of a face (type, radius, axis...).
/// Leaves the range's surfaceType at "other" for free-form and unreadable
/// surfaces.
void classifyFace(const TopoDS_Face& face, CADFaceRange& range) {
    range.surfaceType = CADSurfaceTypeOther;
    range.radius = 0.0;
    range.extent = 0.0;
    range.axisDirection = {};
    try {
        // BRepAdaptor_Surface applies the face's location, so every
        // datum below is already in model coordinates.
        const BRepAdaptor_Surface surface(face);
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        switch (surface.GetType()) {
        case GeomAbs_Plane: {
            const gp_Pln plane = surface.Plane();
            gp_Dir normal = plane.Axis().Direction();
            // gp_Pln's normal follows its coordinate system, which can be
            // left-handed after a mirror; the surface normal is X ^ Y.
            if (!plane.Direct()) normal.Reverse();
            if (reversed) normal.Reverse();
            range.surfaceType = CADSurfaceTypePlane;
            range.axisDirection = point(normal);
            break;
        }
        case GeomAbs_Cylinder: {
            const gp_Cylinder cylinder = surface.Cylinder();
            range.surfaceType = CADSurfaceTypeCylinder;
            range.radius = cylinder.Radius();
            range.axisDirection = point(cylinder.Axis().Direction());
            range.extent = std::abs(surface.LastVParameter() - surface.FirstVParameter());
            break;
        }
        case GeomAbs_Cone: {
            const gp_Cone cone = surface.Cone();
            range.surfaceType = CADSurfaceTypeCone;
            range.radius = cone.RefRadius();
            range.axisDirection = point(cone.Axis().Direction());
            // V runs along the generatrix; project onto the axis.
            range.extent = std::abs(surface.LastVParameter() - surface.FirstVParameter()) * std::cos(cone.SemiAngle());
            break;
        }
        case GeomAbs_Sphere: {
            const gp_Sphere sphere = surface.Sphere();
            range.surfaceType = CADSurfaceTypeSphere;
            range.radius = sphere.Radius();
            break;
        }
        case GeomAbs_Torus: {
            const gp_Torus torus = surface.Torus();
            range.surfaceType = CADSurfaceTypeTorus;
            range.radius = torus.MajorRadius();
            range.axisDirection = point(torus.Axis().Direction());
            break;
        }
        default:
            recoverAnalyticSurface(face, reversed, range);
            break;
        }
        if (!std::isfinite(range.extent)) range.extent = 0.0;
    } catch (const Standard_Failure&) {
        range.surfaceType = CADSurfaceTypeOther;
    }
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

std::array<float, 3> srgb(const Quantity_Color& color) {
    Standard_Real red, green, blue;
    color.Values(red, green, blue, Quantity_TOC_sRGB);
    return {static_cast<float>(red), static_cast<float>(green), static_cast<float>(blue)};
}

/// Applies the colours set on a part's sub-shape labels (faces, or bodies
/// whose faces inherit), parents before children so the most specific wins.
/// Reading the sub-shape labels directly is much faster than asking
/// XCAFDoc_ColorTool::GetColor(face), which searches the whole shape tool
/// for every face.
void applySubShapeColors(const Handle(XCAFDoc_ColorTool)& colorTool,
                         const TDF_Label& parent,
                         std::unordered_map<const TopoDS_TShape*, std::array<float, 3>>& out,
                         int depth) {
    if (depth > 64) return;
    TDF_LabelSequence subShapes;
    XCAFDoc_ShapeTool::GetSubShapes(parent, subShapes);
    for (Standard_Integer index = 1; index <= subShapes.Length(); ++index) {
        const TDF_Label& sub = subShapes.Value(index);
        Quantity_Color color;
        if (colorTool->GetColor(sub, XCAFDoc_ColorSurf, color) || colorTool->GetColor(sub, XCAFDoc_ColorGen, color)) {
            const TopoDS_Shape subShape = XCAFDoc_ShapeTool::GetShape(sub);
            const std::array<float, 3> rgb = srgb(color);
            if (subShape.ShapeType() == TopAbs_FACE) {
                out[subShape.TShape().get()] = rgb;
            } else {
                for (TopExp_Explorer explorer(subShape, TopAbs_FACE); explorer.More(); explorer.Next()) {
                    out[explorer.Current().TShape().get()] = rgb;
                }
            }
        }
        applySubShapeColors(colorTool, sub, out, depth + 1);
    }
}

/// Walks the XDE product structure so instance colours (set on the
/// assembly component that references a part) reach that part's faces, and
/// records the most specific colour for every face: face > body > instance.
void collectFaceColors(const Handle(XCAFDoc_ShapeTool)& shapeTool,
                       const Handle(XCAFDoc_ColorTool)& colorTool,
                       const TDF_Label& label,
                       std::optional<Quantity_Color> inherited,
                       std::unordered_map<const TopoDS_TShape*, std::array<float, 3>>& out,
                       int depth) {
    if (depth > 64 || label.IsNull()) return;
    Quantity_Color own;
    if (colorTool->GetColor(label, XCAFDoc_ColorSurf, own) || colorTool->GetColor(label, XCAFDoc_ColorGen, own)) {
        inherited = own;
    }
    if (shapeTool->IsReference(label)) {
        TDF_Label referred;
        if (shapeTool->GetReferredShape(label, referred)) {
            collectFaceColors(shapeTool, colorTool, referred, inherited, out, depth + 1);
        }
        return;
    }
    if (shapeTool->IsAssembly(label)) {
        TDF_LabelSequence components;
        shapeTool->GetComponents(label, components);
        for (Standard_Integer index = 1; index <= components.Length(); ++index) {
            collectFaceColors(shapeTool, colorTool, components.Value(index), inherited, out, depth + 1);
        }
        return;
    }
    const TopoDS_Shape shape = shapeTool->GetShape(label);
    if (shape.IsNull()) return;
    if (inherited) {
        const std::array<float, 3> rgb = srgb(*inherited);
        for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
            out[explorer.Current().TShape().get()] = rgb;
        }
    }
    applySubShapeColors(colorTool, label, out, 0);
}

/// STEPControl_Reader's default shape-healing parameters and operations,
/// computed once. They are protected in OCCT; this subclass only exposes them.
struct StepShapeFixDefaults : STEPControl_Reader {
    using STEPControl_Reader::GetDefaultShapeFixParameters;
    using STEPControl_Reader::GetDefaultShapeProcessFlags;
};

/// The STEP translator's default healing, except that self-intersecting
/// wires are not fixed: that pass dominates translation time on large
/// assemblies and is not needed for display. Disabling any other fix mode
/// breaks meshing of real files, so everything else stays at the default.
const std::pair<DE_ShapeFixParameters, ShapeProcess::OperationsFlags>& stepShapeFixSettings() {
    static const std::pair<DE_ShapeFixParameters, ShapeProcess::OperationsFlags> settings = [] {
        const StepShapeFixDefaults defaults;
        DE_ShapeFixParameters parameters = defaults.GetDefaultShapeFixParameters();
        parameters.FixSelfIntersectionMode = DE_ShapeFixParameters::FixMode::NotFix;
        return std::make_pair(parameters, defaults.GetDefaultShapeProcessFlags());
    }();
    return settings;
}

bool importShape(CADBridgeModel& model,
                 const std::filesystem::path& path,
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
        const IFSelect_ReturnStatus readStatus = reader.ReadFile(nativePath.c_str());
        // ReadFile has no progress hook; this is the first chance to stop.
        checkpoint(model);
        if (readStatus != IFSelect_RetDone) {
            error = "Open CASCADE could not parse the STEP file.";
            return false;
        }
        // Set after ReadFile, which fills in any parameters still missing.
        const auto& [shapeFixParameters, shapeProcessFlags] = stepShapeFixSettings();
        reader.SetShapeFixParameters(shapeFixParameters);
        reader.SetShapeProcessFlags(shapeProcessFlags);
        // Assemblies with instance-specific overrides (SHUO) get
        // XCAFDoc_GraphNode attributes whose father/child handles form
        // cycles. Neither dropping the last Handle nor
        // TDocStd_Application::Close() breaks them (OCCT 7.9: a PCB
        // assembly leaked 4 MB of nodes per import, forever, in the
        // long-lived Quick Look extension processes). Forgetting the
        // attributes explicitly runs XCAFDoc_GraphNode::BeforeForget, which
        // unlinks them, and then Close() frees the document.
        const Handle(XCAFApp_Application) application = XCAFApp_Application::GetApplication();
        Handle(TDocStd_Document) document;
        application->NewDocument("BinXCAF", document);
        struct DocumentCloser {
            Handle(XCAFApp_Application) application;
            Handle(TDocStd_Document) document;
            ~DocumentCloser() {
                if (document.IsNull()) return;
                try { document->Main().ForgetAllAttributes(Standard_True); } catch (...) {}
                try { application->Close(document); } catch (...) {}
            }
        } closer{application, document};
        Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageTranslating, 0);
        const bool transferred = reader.Transfer(document, progress->Start());
        // Before the result check: a user break makes Transfer return false.
        checkpoint(model);
        if (!transferred) {
            error = "The STEP file did not contain any transferable shapes.";
            return false;
        }
        const Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        TDF_LabelSequence freeShapes;
        shapeTool->GetFreeShapes(freeShapes);
        shape = XCAFDoc_ShapeTool::GetOneShape(freeShapes);
        try {
            const Handle(XCAFDoc_ColorTool) colorTool = XCAFDoc_DocumentTool::ColorTool(document->Main());
            for (Standard_Integer index = 1; index <= freeShapes.Length(); ++index) {
                collectFaceColors(shapeTool, colorTool, freeShapes.Value(index), std::nullopt, model.faceColors, 0);
            }
        } catch (const Standard_Failure&) {
            model.faceColors.clear();
        }
        checkpoint(model);
        if (shape.IsNull()) {
            // Keep a compatibility path for unusual STEP files that transfer
            // geometry but do not expose a conventional XDE free-shape label.
            shape = reader.Reader().OneShape();
        }
    } else if (extension == ".iges" || extension == ".igs") {
        IGESControl_Reader reader;
        const IFSelect_ReturnStatus readStatus = reader.ReadFile(nativePath.c_str());
        checkpoint(model);
        if (readStatus != IFSelect_RetDone) {
            error = "Open CASCADE could not parse the IGES file.";
            return false;
        }
        Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageTranslating, 0);
        const Standard_Integer transferred = reader.TransferRoots(progress->Start());
        checkpoint(model);
        if (transferred <= 0) {
            error = "The IGES file did not contain any transferable shapes.";
            return false;
        }
        shape = reader.OneShape();
    } else if (extension == ".brep" || extension == ".rle") {
        BRep_Builder builder;
        Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(model, CADLoadStageReading, 0);
        const bool read = BRepTools::Read(shape, nativePath.c_str(), builder, progress->Start());
        checkpoint(model);
        if (!read) {
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

double boxDiagonal(const Bnd_Box& box) {
    if (box.IsVoid()) return 0.0;
    Standard_Real minX, minY, minZ, maxX, maxY, maxZ;
    box.Get(minX, minY, minZ, maxX, maxY, maxZ);
    const double dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

CADBounds computeBounds(CADBridgeModel& model, const TopoDS_Shape& shape) {
    CADBounds result{};
    if (shape.IsNull()) return result;
    // Instanced assemblies can have millions of face instances; stay cancellable.
    size_t visited = 0;
    const auto poll = [&model, &visited] {
        if ((++visited & 1023u) == 0) checkpoint(model);
    };

    // Vertex-only box (BRepBndLib::AddClose is not vertex-only: it bounds
    // edge curves too, which can be as loose as the surfaces). Cheap, and
    // immune to the loose surface-based bounds below. It is a sanity
    // reference, not the answer, because faces can extend well past their
    // vertices (a full cylinder only has vertices on its seam).
    Bnd_Box vertexBox;
    for (TopExp_Explorer explorer(shape, TopAbs_VERTEX); explorer.More(); explorer.Next()) {
        poll();
        vertexBox.Add(BRep_Tool::Pnt(TopoDS::Vertex(explorer.Current())));
    }
    const double vertexDiagonal = boxDiagonal(vertexBox);
    Bnd_Box reference = vertexBox;
    if (!reference.IsVoid()) {
        reference.Enlarge(std::max(vertexDiagonal, 1.0e-3));
    }

    // Pole/control-point bounds per face: slightly loose but ~1000x cheaper
    // than AddOptimal on NURBS-heavy assemblies. Some exporters write faces
    // whose surface parameter range is vastly larger than the trimmed face
    // (a 20 km cylinder carrying a 20 mm boss), which makes the pole box
    // absurd. Those faces fall back to the exact (optimal) box so the
    // diagonal, and hence the mesh deflection, stays sane. The bounds are
    // tightened from the mesh later anyway.
    Bnd_Box box;
    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        poll();
        Bnd_Box faceBox;
        BRepBndLib::Add(explorer.Current(), faceBox, Standard_False);
        if (!reference.IsVoid() && !faceBox.IsVoid()) {
            Standard_Real minX, minY, minZ, maxX, maxY, maxZ;
            faceBox.Get(minX, minY, minZ, maxX, maxY, maxZ);
            const bool inside = !reference.IsOut(gp_Pnt(minX, minY, minZ)) && !reference.IsOut(gp_Pnt(maxX, maxY, maxZ));
            if (!inside) {
                faceBox.SetVoid();
                BRepBndLib::AddOptimal(explorer.Current(), faceBox, Standard_False, Standard_False);
            }
        }
        box.Add(faceBox);
    }
    // Edges that do not belong to any face (wireframe models), plus vertices.
    for (TopExp_Explorer explorer(shape, TopAbs_EDGE, TopAbs_FACE); explorer.More(); explorer.Next()) {
        BRepBndLib::Add(explorer.Current(), box, Standard_False);
    }
    box.Add(vertexBox);
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

/// Collects the first exception thrown inside an OSD_Parallel loop body, so
/// the loop never throws across worker threads; rethrown after the loop.
class ParallelFailure {
public:
    template <typename Body>
    void run(Body&& body) {
        try {
            body();
        } catch (const Standard_Failure& exception) {
            record(std::string("Open CASCADE error: ") + exception.GetMessageString());
        } catch (const std::bad_alloc&) {
            record("", true);
        } catch (const std::exception& exception) {
            record(std::string("CAD bridge error: ") + exception.what());
        } catch (...) {
            record("Unknown CAD bridge error.");
        }
    }
    bool failed() const { return failed_.load(std::memory_order_relaxed); }
    /// Loading thread only, after the loop.
    void rethrow() const {
        if (!failed()) return;
        if (outOfMemory_) throw std::bad_alloc();
        throw std::runtime_error(message_);
    }

private:
    void record(std::string message, bool outOfMemory = false) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (failed_.load(std::memory_order_relaxed)) return;
        message_ = std::move(message);
        outOfMemory_ = outOfMemory;
        failed_.store(true, std::memory_order_relaxed);
    }
    std::atomic<bool> failed_{false};
    std::mutex mutex_;
    std::string message_;
    bool outOfMemory_ = false;
};

/// Reports progress from an OSD_Parallel loop every ~2% of `total` items.
class ParallelProgress {
public:
    ParallelProgress(CADBridgeModel& model, CADLoadStage stage, size_t total)
        : model_(model), stage_(stage), total_(total), step_(std::max<size_t>(1, total / 50)) {}
    void advance() {
        const size_t done = done_.fetch_add(1, std::memory_order_relaxed) + 1;
        if (done % step_ == 0) {
            reportProgress(model_, stage_, static_cast<double>(done) / static_cast<double>(total_),
                           static_cast<uint32_t>(std::min<size_t>(total_, UINT32_MAX)));
        }
    }

private:
    CADBridgeModel& model_;
    CADLoadStage stage_;
    size_t total_;
    size_t step_;
    std::atomic<size_t> done_{0};
};

/// Copies every face instance's triangulation into the display arrays. Two
/// passes: count nodes and triangles per face (prefix sums give each face its
/// slice), then fill the slices in parallel. Instances share one
/// Poly_Triangulation, so normals are computed once per triangulation.
void buildMesh(CADBridgeModel& model, bool parallel) {
    model.vertices.clear();
    model.triangles.clear();
    model.faceRanges.clear();
    model.faces.clear();

    // The budget gate, before anything is allocated per face instance. It
    // also keeps the uint32 indices far below 2^32.
    {
        size_t nodeTotal = 0;
        size_t triangleTotal = 0;
        size_t instances = 0;
        for (TopExp_Explorer explorer(model.shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
            if (++instances > kMaxFaces) abortTooComplex(model, AbortReason::tooManyFaces, kMaxFaces, kMaxFaces);
            if ((instances & 4095u) == 0) checkpoint(model);
            TopLoc_Location location;
            const Handle(Poly_Triangulation)& triangulation = BRep_Tool::Triangulation(TopoDS::Face(explorer.Current()), location);
            if (triangulation.IsNull() || triangulation->NbNodes() == 0) continue;
            nodeTotal += static_cast<size_t>(triangulation->NbNodes());
            triangleTotal += static_cast<size_t>(triangulation->NbTriangles());
        }
        if (triangleTotal > model.maxTriangles || nodeTotal > model.maxTriangles) {
            abortTooComplex(model, AbortReason::tooManyTriangles, std::max(triangleTotal, nodeTotal), model.maxTriangles);
        }
    }

    for (TopExp_Explorer explorer(model.shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        model.faces.push_back(TopoDS::Face(explorer.Current()));
    }
    const size_t faceCount = model.faces.size();
    std::vector<Handle(Poly_Triangulation)> triangulations(faceCount);
    std::vector<TopLoc_Location> locations(faceCount);
    std::vector<size_t> nodeBase(faceCount + 1, 0);
    std::vector<size_t> triangleBase(faceCount + 1, 0);
    // One face per distinct triangulation, for the normals.
    std::vector<size_t> triangulationOwners;
    {
        NCollection_Map<Standard_Address> seen;
        for (size_t index = 0; index < faceCount; ++index) {
            triangulations[index] = BRep_Tool::Triangulation(model.faces[index], locations[index]);
            const Handle(Poly_Triangulation)& triangulation = triangulations[index];
            const size_t nodes = triangulation.IsNull() ? 0 : static_cast<size_t>(triangulation->NbNodes());
            const size_t triangles = nodes == 0 ? 0 : static_cast<size_t>(triangulation->NbTriangles());
            nodeBase[index + 1] = nodeBase[index] + nodes;
            triangleBase[index + 1] = triangleBase[index] + triangles;
            if (nodes > 0 && seen.Add(triangulation.get())) triangulationOwners.push_back(index);
        }
    }
    const size_t nodeTotal = nodeBase[faceCount];
    const size_t triangleTotal = triangleBase[faceCount];
    checkpoint(model);

    ParallelFailure failure;
    OSD_Parallel::For(0, static_cast<int>(triangulationOwners.size()), [&](int owner) {
        if (failure.failed() || shouldAbort(model)) return;
        failure.run([&] {
            const size_t index = triangulationOwners[static_cast<size_t>(owner)];
            // Uses the face only for its (location-free) surface.
            BRepLib_ToolTriangulatedShape::ComputeNormals(model.faces[index], triangulations[index]);
        });
    }, !parallel);
    checkpoint(model);
    failure.rethrow();

    model.vertices.resize(nodeTotal);
    model.triangles.resize(triangleTotal);
    model.faceRanges.resize(faceCount);
    ParallelProgress progress(model, CADLoadStageBuildingMesh, faceCount);
    OSD_Parallel::For(0, static_cast<int>(faceCount), [&](int faceIndex) {
        if (failure.failed() || shouldAbort(model)) return;
        failure.run([&] {
            const size_t index = static_cast<size_t>(faceIndex);
            const TopoDS_Face& face = model.faces[index];
            CADFaceRange range{};
            range.firstTriangle = static_cast<uint32_t>(triangleBase[index]);
            range.triangleCount = static_cast<uint32_t>(triangleBase[index + 1] - triangleBase[index]);
            range.exactArea = -1.0; // computed on demand (CADBridgeModelFaceArea)
            classifyFace(face, range);
            if (const auto color = model.faceColors.find(face.TShape().get()); color != model.faceColors.end()) {
                range.red = color->second[0];
                range.green = color->second[1];
                range.blue = color->second[2];
                range.hasColor = 1;
            }
            model.faceRanges[index] = range;
            if (range.triangleCount > 0) {
                const Handle(Poly_Triangulation)& triangulation = triangulations[index];
                const gp_Trsf transformation = locations[index].Transformation();
                const bool reversed = face.Orientation() == TopAbs_REVERSED;
                const bool hasNormals = triangulation->HasNormals();
                CADVertex *vertex = model.vertices.data() + nodeBase[index];
                for (Standard_Integer node = 1; node <= triangulation->NbNodes(); ++node) {
                    gp_Pnt position = triangulation->Node(node);
                    position.Transform(transformation);
                    gp_Dir normal(0.0, 0.0, 1.0);
                    if (hasNormals) {
                        normal = triangulation->Normal(node);
                        normal.Transform(transformation);
                        if (reversed) normal.Reverse();
                    }
                    *vertex++ = {
                        static_cast<float>(position.X()), static_cast<float>(position.Y()), static_cast<float>(position.Z()),
                        static_cast<float>(normal.X()), static_cast<float>(normal.Y()), static_cast<float>(normal.Z())
                    };
                }
                const uint32_t vertexBase = static_cast<uint32_t>(nodeBase[index]);
                CADTriangle *triangle = model.triangles.data() + triangleBase[index];
                for (Standard_Integer triangleIndex = 1; triangleIndex <= triangulation->NbTriangles(); ++triangleIndex) {
                    Standard_Integer a, b, c;
                    triangulation->Triangle(triangleIndex).Get(a, b, c);
                    if (reversed) std::swap(b, c);
                    *triangle++ = {
                        vertexBase + static_cast<uint32_t>(a - 1),
                        vertexBase + static_cast<uint32_t>(b - 1),
                        vertexBase + static_cast<uint32_t>(c - 1),
                        static_cast<uint32_t>(index)
                    };
                }
            }
        });
        progress.advance();
    }, !parallel);
    checkpoint(model);
    failure.rethrow();
}

double exactEdgeLength(const TopoDS_Edge& edge) {
    GProp_GProps properties;
    BRepGProp::LinearProperties(edge, properties, Standard_True, Standard_False);
    return properties.Mass();
}

/// Exporters often write circular edges as B-splines. Try to recover the
/// circle (or line) so the viewer can report a diameter.
void recoverAnalyticCurve(const TopoDS_Edge& edge, CADEdgePolyline& polyline) {
    TopLoc_Location location;
    Standard_Real first, last;
    const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, location, first, last);
    if (curve.IsNull() || !std::isfinite(first) || !std::isfinite(last)) return;
    GeomConvert_CurveToAnaCurve converter(curve);
    converter.SetConvType(GeomConvert_MinGap);
    Handle(Geom_Curve) analytic;
    Standard_Real newFirst = first, newLast = last;
    if (!converter.ConvertToAnalytical(analyticTolerance, analytic, first, last, newFirst, newLast) || analytic.IsNull()) {
        return;
    }
    // Transform a copy: for an ellipse (and a line basis) the converter
    // returns the edge's own curve, and transforming that in place moved the
    // shared B-Rep geometry of every located instance.
    analytic = Handle(Geom_Curve)::DownCast(analytic->Transformed(location.Transformation()));
    if (analytic.IsNull()) return;
    if (Handle(Geom_Circle) circle = Handle(Geom_Circle)::DownCast(analytic)) {
        const gp_Circ circ = circle->Circ();
        polyline.isCircular = 1;
        polyline.curveType = CADCurveTypeCircle;
        polyline.exactDiameter = circ.Radius() * 2.0;
        polyline.direction = point(circ.Axis().Direction());
    } else if (Handle(Geom_Line) line = Handle(Geom_Line)::DownCast(analytic)) {
        polyline.curveType = CADCurveTypeLine;
        polyline.direction = point(line->Lin().Direction());
    }
}

/// Fills the analytic curve metadata of an edge (type, circle axis, line
/// direction).
void classifyEdge(const TopoDS_Edge& edge, CADEdgePolyline& polyline) {
    polyline.isCircular = 0;
    polyline.exactDiameter = 0.0;
    polyline.curveType = CADCurveTypeOther;
    polyline.direction = {};
    try {
        const BRepAdaptor_Curve curve(edge);
        switch (curve.GetType()) {
        case GeomAbs_Circle: {
            const gp_Circ circle = curve.Circle();
            polyline.isCircular = 1;
            polyline.curveType = CADCurveTypeCircle;
            polyline.exactDiameter = circle.Radius() * 2.0;
            polyline.direction = point(circle.Axis().Direction());
            break;
        }
        case GeomAbs_Line: {
            polyline.curveType = CADCurveTypeLine;
            polyline.direction = point(curve.Line().Direction());
            break;
        }
        default:
            recoverAnalyticCurve(edge, polyline);
            break;
        }
    } catch (const Standard_Failure&) {
        // Some degenerate edges do not expose an adaptable 3D curve. They are
        // valid topology, but intentionally remain unclassified.
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

/// Emits the edge's polygon on an adjacent face's triangulation: the edge
/// as the shaded mesh draws it, so lines sit exactly on the triangle seams
/// (independently sampled curves can float above or sink below the mesh).
/// BRep_Tool composes the polygon's location with the edge's, so instances
/// of a part meshed once as a location-free prototype get their own
/// placement. False when the edge has no usable polygon.
bool appendMeshPolygon(const TopoDS_Edge& edge, std::vector<CADPoint3D>& points) {
    if (BRep_Tool::Degenerated(edge)) return false;
    Handle(Poly_PolygonOnTriangulation) polygon;
    Handle(Poly_Triangulation) triangulation;
    TopLoc_Location location;
    BRep_Tool::PolygonOnTriangulation(edge, polygon, triangulation, location);
    if (polygon.IsNull() || triangulation.IsNull() || polygon->NbNodes() < 2) return false;
    const TColStd_Array1OfInteger& nodes = polygon->Nodes();
    const Standard_Integer nodeCount = triangulation->NbNodes();
    const gp_Trsf transformation = location.Transformation();
    const size_t initialSize = points.size();
    points.reserve(initialSize + static_cast<size_t>(nodes.Length()));
    for (Standard_Integer index = nodes.Lower(); index <= nodes.Upper(); ++index) {
        const Standard_Integer node = nodes(index);
        if (node < 1 || node > nodeCount) {
            points.resize(initialSize);
            return false;
        }
        points.push_back(point(triangulation->Node(node).Transformed(transformation)));
    }
    return true;
}

/// Whether `edge` is a seam or degenerated: geometry that real CAD viewers
/// never draw. A seam appears twice in the wire of a face it bounds
/// (BRep_Tool::IsClosed); a boundary between two different faces is never
/// one, even when they are tangent.
uint8_t isHiddenEdge(const TopoDS_Edge& edge, const TopTools_ListOfShape* faces) {
    if (BRep_Tool::Degenerated(edge)) return 1;
    if (!faces) return 0;
    for (TopTools_ListIteratorOfListOfShape it(*faces); it.More(); it.Next()) {
        if (BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) return 1;
    }
    return 0;
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

void buildEdges(CADBridgeModel& model, double edgeDeflection, bool parallel) {
    model.edges.clear();
    model.edgeShapes.clear();
    model.polylinePoints.clear();

    TopTools_IndexedMapOfShape edgeMap;
    TopExp::MapShapes(model.shape, TopAbs_EDGE, edgeMap);
    const size_t edgeCount = static_cast<size_t>(edgeMap.Extent());
    if (edgeCount > kMaxEdges) abortTooComplex(model, AbortReason::tooManyEdges, edgeCount, kMaxEdges);
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(model.shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    checkpoint(model);

    model.edges.resize(edgeCount);
    model.edgeShapes.resize(edgeCount);
    // Pass 1 samples every edge into its own buffer; pass 2 concatenates.
    std::vector<std::vector<CADPoint3D>> samples(edgeCount);
    std::atomic<size_t> pointTotal{0};
    ParallelFailure failure;
    ParallelProgress progress(model, CADLoadStageSamplingEdges, edgeCount);
    OSD_Parallel::For(0, static_cast<int>(edgeCount), [&](int edgeIndex) {
        if (failure.failed() || shouldAbort(model)) return;
        failure.run([&] {
            const size_t index = static_cast<size_t>(edgeIndex);
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(edgeIndex + 1));
            model.edgeShapes[index] = edge;
            std::vector<CADPoint3D>& points = samples[index];
            if (!appendMeshPolygon(edge, points)) appendEdgeSamples(edge, edgeDeflection, points);
            const size_t total = pointTotal.fetch_add(points.size(), std::memory_order_relaxed) + points.size();
            if (total > model.maxPoints) {
                recordLimit(model, AbortReason::tooManyPoints, model.maxPoints, model.maxPoints);
                return;
            }
            CADEdgePolyline polyline{};
            polyline.exactLength = -1.0; // computed on demand (CADBridgeModelEdgeLength)
            classifyEdge(edge, polyline);
            const TopTools_ListOfShape* faces = edgeFaces.Seek(edge);
            polyline.isTangent = isTangentEdge(edge, faces);
            polyline.isHidden = isHiddenEdge(edge, faces);
            model.edges[index] = polyline;
        });
        progress.advance();
    }, !parallel);
    checkpoint(model);
    failure.rethrow();

    model.polylinePoints.reserve(pointTotal.load(std::memory_order_relaxed));
    for (size_t index = 0; index < edgeCount; ++index) {
        std::vector<CADPoint3D>& points = samples[index];
        model.edges[index].firstPoint = static_cast<uint32_t>(model.polylinePoints.size());
        model.edges[index].pointCount = static_cast<uint32_t>(points.size());
        model.polylinePoints.insert(model.polylinePoints.end(), points.begin(), points.end());
        std::vector<CADPoint3D>().swap(points);
    }
}

/// Faces per BRepMesh call. BRepMesh keeps its whole working model in one
/// arena that is only freed when the call returns, and its edge
/// discretisation (about 30 KB per edge, measured) cannot be interrupted, so
/// meshing everything at once costs memory proportional to the model and
/// cannot be stopped. Batches bound both.
constexpr size_t kMeshBatchFaces = 2048;

/// Splits the prototype faces into compounds of about kMeshBatchFaces faces.
/// Faces that share an edge always land in the same batch, so every edge is
/// discretised once, with all of its faces, exactly as in a single call.
std::vector<TopoDS_Compound> meshBatches(const TopTools_IndexedMapOfShape& faces) {
    const Standard_Integer faceCount = faces.Extent();
    std::vector<int> parent(static_cast<size_t>(faceCount) + 1);
    for (size_t index = 0; index < parent.size(); ++index) parent[index] = static_cast<int>(index);
    const auto root = [&parent](int index) {
        while (parent[static_cast<size_t>(index)] != index) {
            parent[static_cast<size_t>(index)] = parent[static_cast<size_t>(parent[static_cast<size_t>(index)])];
            index = parent[static_cast<size_t>(index)];
        }
        return index;
    };
    {
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        for (Standard_Integer index = 1; index <= faceCount; ++index) {
            TopExp::MapShapesAndAncestors(faces(index), TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        }
        for (Standard_Integer edge = 1; edge <= edgeFaces.Extent(); ++edge) {
            const TopTools_ListOfShape& adjacent = edgeFaces(edge);
            const int first = root(faces.FindIndex(adjacent.First()));
            for (TopTools_ListOfShape::Iterator face(adjacent); face.More(); face.Next()) {
                const int other = root(faces.FindIndex(face.Value()));
                if (other != first) parent[static_cast<size_t>(other)] = first;
            }
        }
    }
    // Components in order of their first face; a component is never split.
    std::vector<std::vector<int>> components;
    std::unordered_map<int, size_t> componentOfRoot;
    for (Standard_Integer index = 1; index <= faceCount; ++index) {
        const auto [entry, inserted] = componentOfRoot.try_emplace(root(index), components.size());
        if (inserted) components.emplace_back();
        components[entry->second].push_back(index);
    }
    std::vector<TopoDS_Compound> batches;
    BRep_Builder builder;
    size_t batchFaces = kMeshBatchFaces;
    for (const std::vector<int>& component : components) {
        if (batchFaces >= kMeshBatchFaces) {
            batches.emplace_back();
            builder.MakeCompound(batches.back());
            batchFaces = 0;
        }
        for (const int index : component) builder.Add(batches.back(), faces(index));
        batchFaces += component.size();
    }
    return batches;
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
    // Before the null check: a user break makes ReadFile return no mesh.
    checkpoint(model);
    if (mesh.IsNull() || mesh->NbTriangles() == 0 || mesh->NbNodes() == 0) {
        error = "Open CASCADE could not parse the STL file.";
        return false;
    }
    const size_t stlTriangles = static_cast<size_t>(mesh->NbTriangles());
    const size_t stlNodes = static_cast<size_t>(mesh->NbNodes());
    if (stlTriangles > model.maxTriangles || stlNodes > model.maxTriangles) {
        abortTooComplex(model, AbortReason::tooManyTriangles, std::max(stlTriangles, stlNodes), model.maxTriangles);
    }
    const uint32_t triangleCount = static_cast<uint32_t>(stlTriangles);
    reportProgress(model, CADLoadStageBuildingMesh, -1.0, triangleCount);
    mesh->ComputeNormals();
    checkpoint(model);

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
    CADFaceRange range{};
    range.firstTriangle = 0;
    range.triangleCount = static_cast<uint32_t>(model.triangles.size());
    range.exactArea = area;
    model.faceRanges.push_back(range);
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
    return {0.0, 0.15, 0.0, 1, 1.0};
}

CADBridgeCancelToken *CADBridgeCancelTokenCreate(uint64_t memoryBudgetBytes) {
    try {
        CADBridgeCancelToken *token = new CADBridgeCancelToken();
        token->memoryBudget = memoryBudgetBytes;
        return token;
    } catch (...) {
        return nullptr;
    }
}

void CADBridgeCancelTokenCancel(CADBridgeCancelToken *token) {
    if (token) token->cancelled.store(true, std::memory_order_relaxed);
}

void CADBridgeCancelTokenRelease(CADBridgeCancelToken *token) {
    if (token && token->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete token;
}

void CADBridgeModelSetCancelToken(CADBridgeModel *model, CADBridgeCancelToken *token) {
    if (!model) return;
    if (token) token->refs.fetch_add(1, std::memory_order_relaxed);
    CADBridgeCancelToken *previous = nullptr;
    {
        std::lock_guard<std::mutex> lock(model->tokenMutex);
        previous = model->cancelToken;
        model->cancelToken = token;
    }
    CADBridgeCancelTokenRelease(previous);
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
    CADBridgeTrimMemory();
}

void CADBridgeTrimMemory(void) {
    // A STEP import allocates and frees hundreds of megabytes of small
    // blocks. malloc keeps those pages for reuse, so a window that has been
    // closed still shows the model's worth of memory in Activity Monitor.
    // Ask every zone to hand its empty pages back to the kernel now.
    malloc_zone_pressure_relief(nullptr, 0);
}

void CADBridgeModelReleaseDisplayData(CADBridgeModel *model) {
    if (!model) return;
    // swap() rather than clear(): clear() keeps the capacity allocated.
    std::vector<CADVertex>().swap(model->vertices);
    std::vector<CADTriangle>().swap(model->triangles);
    std::vector<CADPoint3D>().swap(model->polylinePoints);
    model->faceColors.clear();
    // Drop the per-face Poly_Triangulation (and polygons on it) that
    // BRepMesh attached to the shape. Measurement (BRepExtrema, BRepGProp
    // with UseTriangulation = false) works on the exact geometry and does
    // not need it. On a typical assembly this is the largest single block
    // of memory the model owns.
    if (!model->shape.IsNull()) {
        try { BRepTools::Clean(model->shape); } catch (...) {}
    }
    CADBridgeTrimMemory();
}

namespace {

bool isPositiveFinite(double value) {
    return std::isfinite(value) && value > 0.0;
}

/// Retains the model's cancel token for the duration of one load and sets
/// that load's size limits from its memory budget.
class ActiveLoad {
public:
    explicit ActiveLoad(CADBridgeModel& model) : model_(model) {
        {
            std::lock_guard<std::mutex> lock(model.tokenMutex);
            model.activeToken = model.cancelToken;
            if (model.activeToken) model.activeToken->refs.fetch_add(1, std::memory_order_relaxed);
        }
        model.abortReason.store(static_cast<int>(AbortReason::none), std::memory_order_relaxed);
        model.abortPollCounter.store(0, std::memory_order_relaxed);
        model.mallocRetained.store(0, std::memory_order_relaxed);
        model.retainedSamplesLeft.store(0, std::memory_order_relaxed);
        model.limitCount = 0;
        model.limitValue = 0;
        const uint64_t budget = model.activeToken ? model.activeToken->memoryBudget : 0;
        model.maxTriangles = budget > 0 ? static_cast<size_t>(std::min<uint64_t>(kMaxTriangles, budget / kBytesPerTriangle)) : kMaxTriangles;
        model.maxPoints = budget > 0 ? static_cast<size_t>(std::min<uint64_t>(kMaxPoints, budget / kBytesPerPoint)) : kMaxPoints;
    }
    ~ActiveLoad() {
        CADBridgeCancelTokenRelease(model_.activeToken);
        model_.activeToken = nullptr;
    }
    ActiveLoad(const ActiveLoad&) = delete;
    ActiveLoad& operator=(const ActiveLoad&) = delete;

private:
    CADBridgeModel& model_;
};

/// Frees whatever a failed or stopped load left behind and records the error.
CADBridgeStatus failLoad(CADBridgeModel& model, CADBridgeStatus status, std::string message) {
    releaseModelData(model);
    CADBridgeTrimMemory();
    return fail(model, status, std::move(message));
}

} // namespace

CADBridgeStatus CADBridgeModelLoad(CADBridgeModel *model, const char *pathUTF8, CADMeshOptions options) {
    if (!model || !pathUTF8 || pathUTF8[0] == '\0') {
        if (model) model->error = "A non-empty UTF-8 file path is required.";
        return CADBridgeStatusInvalidArgument;
    }

    clearModel(*model);
    ActiveLoad activeLoad(*model);
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
                return failLoad(*model, CADBridgeStatusImportFailed, std::move(meshError));
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
            imported = importShape(*model, path, model->shape, importError);
        }
        if (!imported) {
            const std::string extension = lowercaseExtension(path);
            const bool unsupported = extension != ".step" && extension != ".stp" &&
                                     extension != ".iges" && extension != ".igs" &&
                                     extension != ".brep" && extension != ".rle";
            return failLoad(*model, unsupported ? CADBridgeStatusUnsupportedFormat : CADBridgeStatusImportFailed,
                            std::move(importError));
        }

        model->bounds = computeBounds(*model, model->shape);
        checkpoint(*model);
        const double diagonal = model->bounds.isValid ? boundsDiagonal(model->bounds) : 0.0;
        if (!std::isfinite(diagonal) || diagonal <= 1.0e-9) {
            return failLoad(*model, CADBridgeStatusImportFailed,
                            "The model has no measurable size, its bounding box is empty or invalid.");
        }
        // The distinct faces to mesh (location-free, so one per TShape), and
        // the number of face instances in the model.
        TopTools_IndexedMapOfShape prototypeFaces;
        size_t faceInstances = 0;
        for (TopExp_Explorer explorer(model->shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
            if (++faceInstances > kMaxFaces) abortTooComplex(*model, AbortReason::tooManyFaces, kMaxFaces, kMaxFaces);
            if ((faceInstances & 4095u) == 0) checkpoint(*model);
            prototypeFaces.Add(explorer.Current().Located(TopLoc_Location()).Oriented(TopAbs_FORWARD));
        }
        const double faceCount = static_cast<double>(faceInstances);
        // Large assemblies (thousands of faces) are viewed as a whole, so
        // they can use a coarser mesh than a single part without looking worse.
        const double complexity = std::clamp(faceCount / 2000.0, 1.0, 4.0);
        // Caller values that are NaN, infinite or not positive mean "automatic".
        // No deflection may go below 1e-4 of the diagonal: finer meshes only
        // cost memory (tens of millions of triangles) without looking better.
        const double minimumDeflection = diagonal * 1.0e-4;
        double automaticLinear = diagonal * 0.0004 * complexity *
            (isPositiveFinite(options.linearDeflectionScale) ? options.linearDeflectionScale : 1.0);
        if (!std::isfinite(automaticLinear)) automaticLinear = diagonal * 0.0004 * complexity;
        const double linearDeflection = std::max(
            isPositiveFinite(options.linearDeflection) ? options.linearDeflection : automaticLinear, minimumDeflection);
        const double angularDeflection = isPositiveFinite(options.angularDeflectionRadians)
            ? std::clamp(options.angularDeflectionRadians, 0.05, 1.0) : std::min(0.15 * complexity, 0.35);
        const double edgeDeflection = std::max(
            isPositiveFinite(options.edgeDeflection) ? options.edgeDeflection : linearDeflection, minimumDeflection);

        IMeshTools_Parameters meshParameters;
        meshParameters.Deflection = linearDeflection;
        meshParameters.Angle = angularDeflection;
        meshParameters.Relative = Standard_False;
        meshParameters.InParallel = options.parallel ? Standard_True : Standard_False;
        // Mesh each face TShape (prototypeFaces) once. An assembly instances
        // its parts, and BRepMesh would otherwise build its working model (and
        // discretise every edge) once per instance. The triangulation lives on the
        // TShape, location-free, so every instance picks it up, and the
        // polygons it leaves on the edges compose with each instance's
        // location (BRep_Tool::PolygonOnTriangulation).
        const std::vector<TopoDS_Compound> batches = meshBatches(prototypeFaces);
        checkpoint(*model);
        {
            Handle(BridgeProgressIndicator) meshProgress =
                new BridgeProgressIndicator(*model, CADLoadStageMeshing, static_cast<uint32_t>(faceCount));
            Message_ProgressScope meshScope(meshProgress->Start(), "Meshing", static_cast<Standard_Real>(batches.size()));
            bool meshed = true;
            for (const TopoDS_Compound& batch : batches) {
                BRepMesh_IncrementalMesh mesher(batch, meshParameters, meshScope.Next());
                // Before the IsDone check, so a user break is not reported
                // as a meshing failure.
                checkpoint(*model);
                meshed = meshed && mesher.IsDone();
            }
            if (!meshed) {
                return failLoad(*model, CADBridgeStatusMeshingFailed, "Open CASCADE could not tessellate the imported shape.");
            }
        }

        // BRepMesh sometimes leaves a real face empty (a hole in the model)
        // when the assembly-wide deflection is coarse for that face. Mesh
        // those again with a deflection scaled to the face itself.
        checkpoint(*model);
        const double minimumArea = 1.0e-6 * diagonal * diagonal;
        for (Standard_Integer index = 1; index <= prototypeFaces.Extent(); ++index) {
            const TopoDS_Face& face = TopoDS::Face(prototypeFaces(index));
            TopLoc_Location location;
            if (!BRep_Tool::Triangulation(face, location).IsNull()) continue;
            checkpoint(*model);
            try {
                if (!(exactFaceArea(face) > minimumArea)) continue;
                Bnd_Box faceBox;
                BRepBndLib::Add(face, faceBox, Standard_False);
                const double faceDiagonal = boxDiagonal(faceBox);
                if (!std::isfinite(faceDiagonal)) continue;
                IMeshTools_Parameters faceParameters = meshParameters;
                faceParameters.Deflection = std::max(faceDiagonal * 0.0004, minimumDeflection);
                faceParameters.InParallel = Standard_False;
                BRepMesh_IncrementalMesh faceMesher(face, faceParameters);
            } catch (const Standard_Failure&) {
                // The face stays empty, as before.
            }
        }

        buildMesh(*model, options.parallel != 0);
        checkpoint(*model);
        buildEdges(*model, edgeDeflection, options.parallel != 0);
        checkpoint(*model);
        tightenBounds(*model);
        reportProgress(*model, CADLoadStageFinishing, -1.0);
        model->stats = computeStats(*model);
        if (model->triangles.empty()) {
            return failLoad(*model, CADBridgeStatusMeshingFailed, "The imported shape did not produce any display triangles.");
        }
        return CADBridgeStatusOK;
    } catch (const LoadAborted& aborted) {
        return failLoad(*model, aborted.status, aborted.message);
    } catch (const std::bad_alloc&) {
        return failLoad(*model, CADBridgeStatusResourceLimit,
                        "Stopped loading: there was not enough memory to open this model.");
    } catch (const Standard_Failure& exception) {
        return failLoad(*model, CADBridgeStatusInternalError,
                        std::string("Open CASCADE error: ") + exception.GetMessageString());
    } catch (const std::exception& exception) {
        return failLoad(*model, CADBridgeStatusInternalError,
                        std::string("CAD bridge error: ") + exception.what());
    } catch (...) {
        return failLoad(*model, CADBridgeStatusInternalError, "Unknown CAD bridge error.");
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
    CADMeasureEntity a{CADMeasureEntityKindFace, faceA, {}};
    CADMeasureEntity b{CADMeasureEntityKindFace, faceB, {}};
    return CADBridgeModelMeasureDistance(model, a, b, result);
}

namespace {

/// Resolves a measurement entity to a TopoDS shape; false when out of range.
bool resolveEntity(const CADBridgeModel& model, const CADMeasureEntity& entity, TopoDS_Shape& shape) {
    switch (entity.kind) {
    case CADMeasureEntityKindPoint:
        shape = BRepBuilderAPI_MakeVertex(gp_Pnt(entity.point.x, entity.point.y, entity.point.z)).Vertex();
        return true;
    case CADMeasureEntityKindEdge:
        if (entity.index >= model.edgeShapes.size()) return false;
        shape = model.edgeShapes[entity.index];
        return true;
    case CADMeasureEntityKindFace:
        if (entity.index >= model.faces.size()) return false;
        shape = model.faces[entity.index];
        return true;
    default:
        return false;
    }
}

} // namespace

CADBridgeStatus CADBridgeModelMeasureDistance(CADBridgeModel *model,
                                              CADMeasureEntity a,
                                              CADMeasureEntity b,
                                              CADFaceDistance *result) {
    if (!model || !result) {
        if (model) model->error = "A model and output measurement are required.";
        return CADBridgeStatusInvalidArgument;
    }

    try {
        TopoDS_Shape shapeA, shapeB;
        if (!resolveEntity(*model, a, shapeA) || !resolveEntity(*model, b, shapeB)) {
            return fail(*model, CADBridgeStatusOutOfRange, "Measurement entity is out of range.");
        }
        BRepExtrema_DistShapeShape distance(shapeA, shapeB);
        if (!distance.IsDone() || distance.NbSolution() < 1) {
            return fail(*model, CADBridgeStatusMeasurementFailed,
                        "Open CASCADE could not compute the minimum distance.");
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
        return fail(*model, CADBridgeStatusMeasurementFailed, "Unknown measurement error.");
    }
}

// MARK: - Model cache

namespace {

/// Bump whenever anything that shapes the bridge's output for a given file
/// and options changes: meshing (deflections, batching, re-meshing), edge
/// sampling, face/edge classification, colours, bounds, stats, the face or
/// edge enumeration order, or the layout of any struct in CADBridge.h.
/// Cache entries written by another revision are never read.
constexpr const char *kBridgeOutputRevision = "bridge-2";

/// A write-only streambuf over a malloc'd buffer that grows as needed, so
/// the serialised shape is built in place and handed to the host as is.
class MallocOutputBuffer : public std::streambuf {
public:
    ~MallocOutputBuffer() override { std::free(data_); }

    /// The bytes written; the caller frees them with free(). Null on failure.
    uint8_t *release(size_t& length) {
        if (failed_) return nullptr;
        length = static_cast<size_t>(pptr() - pbase());
        char *data = data_;
        data_ = nullptr;
        setp(nullptr, nullptr);
        if (!data) data = static_cast<char *>(std::malloc(1)); // empty but non-null
        return reinterpret_cast<uint8_t *>(data);
    }

protected:
    int_type overflow(int_type character) override {
        if (traits_type::eq_int_type(character, traits_type::eof())) return traits_type::not_eof(character);
        if (!reserve(1)) return traits_type::eof();
        *pptr() = traits_type::to_char_type(character);
        pbump(1);
        return character;
    }

    std::streamsize xsputn(const char *bytes, std::streamsize count) override {
        if (count <= 0) return 0;
        if (!reserve(static_cast<size_t>(count))) return 0;
        std::memcpy(pptr(), bytes, static_cast<size_t>(count));
        // pbump takes an int; advance in chunks.
        for (std::streamsize left = count; left > 0;) {
            const int step = static_cast<int>(std::min<std::streamsize>(left, INT_MAX));
            pbump(step);
            left -= step;
        }
        return count;
    }

    /// tellp() support only.
    pos_type seekoff(off_type offset, std::ios_base::seekdir direction, std::ios_base::openmode which) override {
        if (offset == 0 && direction == std::ios_base::cur && (which & std::ios_base::out)) {
            return pos_type(static_cast<off_type>(pptr() - pbase()));
        }
        return pos_type(off_type(-1));
    }

private:
    bool reserve(size_t extra) {
        if (failed_) return false;
        const size_t used = static_cast<size_t>(pptr() - pbase());
        const size_t capacity = static_cast<size_t>(epptr() - pbase());
        if (capacity - used >= extra) return true;
        size_t newCapacity = std::max<size_t>(capacity * 2, 1 << 20);
        while (newCapacity - used < extra) newCapacity *= 2;
        char *grown = static_cast<char *>(std::realloc(data_, newCapacity));
        if (!grown) {
            failed_ = true;
            return false;
        }
        data_ = grown;
        setp(data_, data_ + newCapacity);
        for (size_t left = used; left > 0;) {
            const int step = static_cast<int>(std::min<size_t>(left, INT_MAX));
            pbump(step);
            left -= step;
        }
        return true;
    }

    char *data_ = nullptr;
    bool failed_ = false;
};

/// A read-only, seekable streambuf over borrowed bytes (no copy).
class MemoryInputBuffer : public std::streambuf {
public:
    MemoryInputBuffer(const uint8_t *data, size_t length) {
        // std::streambuf wants char*; the get area is never written through.
        char *begin = const_cast<char *>(reinterpret_cast<const char *>(data));
        setg(begin, begin, begin + length);
    }

protected:
    pos_type seekoff(off_type offset, std::ios_base::seekdir direction, std::ios_base::openmode which) override {
        if (!(which & std::ios_base::in)) return pos_type(off_type(-1));
        const off_type size = static_cast<off_type>(egptr() - eback());
        off_type base = 0;
        if (direction == std::ios_base::cur) base = static_cast<off_type>(gptr() - eback());
        else if (direction == std::ios_base::end) base = size;
        const off_type target = base + offset;
        if (target < 0 || target > size) return pos_type(off_type(-1));
        setg(eback(), eback() + target, egptr());
        return pos_type(target);
    }

    pos_type seekpos(pos_type position, std::ios_base::openmode which) override {
        return seekoff(off_type(position), std::ios_base::beg, which);
    }
};

/// A cached exact value, or -1 (recomputed on demand) if it is not one.
double cachedMeasure(double value) {
    return std::isfinite(value) && value >= 0.0 ? value : -1.0;
}

bool finitePoint(const CADPoint3D& value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

} // namespace

uint8_t *CADBridgeModelCopyShapeData(const CADBridgeModel *model, size_t *outLength) {
    if (outLength) *outLength = 0;
    if (!model || !outLength || model->shape.IsNull()) return nullptr;
    try {
        MallocOutputBuffer buffer;
        std::ostream stream(&buffer);
        // No triangulation or normals: the cache keeps the host's display
        // arrays, and measurement uses the exact geometry only.
        BinTools::Write(model->shape, stream, Standard_False, Standard_False, BinTools_FormatVersion_CURRENT);
        stream.flush();
        if (!stream.good()) return nullptr;
        size_t length = 0;
        uint8_t *data = buffer.release(length);
        if (!data) return nullptr;
        if (length == 0) {
            std::free(data);
            return nullptr;
        }
        *outLength = length;
        return data;
    } catch (...) {
        return nullptr;
    }
}

void CADBridgeFree(void *data) {
    std::free(data);
}

CADBridgeStatus CADBridgeModelRestore(CADBridgeModel *model,
                                      const uint8_t *shapeData, size_t shapeLength,
                                      const CADFaceRange *faceRanges, size_t faceCount,
                                      const CADEdgePolyline *edges, size_t edgeCount,
                                      CADBounds bounds, CADModelStats stats) {
    if (!model) return CADBridgeStatusInvalidArgument;
    releaseModelData(*model);

    // Every problem with the entry itself is ImportFailed: the host deletes
    // the entry and loads the file normally.
    const auto invalid = [model](const char *message) {
        return failLoad(*model, CADBridgeStatusImportFailed, std::string("Invalid model cache entry: ") + message);
    };
    if (!shapeData || shapeLength == 0) return invalid("no shape data.");
    if (faceCount == 0 || !faceRanges) return invalid("no faces.");
    if (edgeCount > 0 && !edges) return invalid("missing edge table.");
    if (faceCount > kMaxFaces || edgeCount > kMaxEdges) return invalid("too many faces or edges.");
    if (stats.faceCount != faceCount || stats.edgeCount != edgeCount) return invalid("the stats do not match the tables.");
    for (size_t index = 0; index < faceCount; ++index) {
        const CADFaceRange& range = faceRanges[index];
        const uint64_t end = static_cast<uint64_t>(range.firstTriangle) + range.triangleCount;
        if (end > stats.triangleCount) return invalid("a face's triangles lie outside the mesh.");
    }
    for (size_t index = 0; index < edgeCount; ++index) {
        const uint64_t end = static_cast<uint64_t>(edges[index].firstPoint) + edges[index].pointCount;
        if (end > UINT32_MAX) return invalid("an edge's points lie outside the polylines.");
    }
    if (bounds.isValid && (!finitePoint(bounds.minimum) || !finitePoint(bounds.maximum))) {
        return invalid("the bounds are not finite.");
    }

    // The token's cancel and memory budget apply as in a normal load.
    ActiveLoad activeLoad(*model);
    try {
        reportProgress(*model, CADLoadStageReading, -1.0);
        // BinTools only builds shapes and geometry (no XSControl/Interface
        // static parameters, no resource files), so unlike STEP/IGES
        // translation it does not need importMutex.
        {
            MemoryInputBuffer buffer(shapeData, shapeLength);
            std::istream stream(&buffer);
            Handle(BridgeProgressIndicator) progress = new BridgeProgressIndicator(*model, CADLoadStageReading, 0);
            BinTools::Read(model->shape, stream, progress->Start());
        }
        checkpoint(*model);
        if (model->shape.IsNull()) return invalid("the shape data did not parse.");

        // Same enumerations as buildMesh (faces) and buildEdges (edges), so
        // CADTriangle.faceIndex and edge indices refer to the same entities.
        model->faces.reserve(faceCount);
        size_t visited = 0;
        for (TopExp_Explorer explorer(model->shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
            if (model->faces.size() >= faceCount) return invalid("the shape has more faces than the face table.");
            if ((++visited & 4095u) == 0) checkpoint(*model);
            model->faces.push_back(TopoDS::Face(explorer.Current()));
        }
        if (model->faces.size() != faceCount) return invalid("the shape has fewer faces than the face table.");

        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(model->shape, TopAbs_EDGE, edgeMap);
        checkpoint(*model);
        if (static_cast<size_t>(edgeMap.Extent()) != edgeCount) return invalid("the shape's edge count does not match the edge table.");
        model->edgeShapes.resize(edgeCount);
        for (size_t index = 0; index < edgeCount; ++index) {
            model->edgeShapes[index] = TopoDS::Edge(edgeMap(static_cast<Standard_Integer>(index) + 1));
        }

        // Cached exact areas/lengths are kept (the same code computed them
        // from the same geometry); anything else is recomputed on demand.
        model->faceRanges.assign(faceRanges, faceRanges + faceCount);
        for (CADFaceRange& range : model->faceRanges) range.exactArea = cachedMeasure(range.exactArea);
        model->edges.assign(edges, edges + edgeCount);
        for (CADEdgePolyline& edge : model->edges) edge.exactLength = cachedMeasure(edge.exactLength);

        model->bounds = bounds;
        model->stats = stats;
        reportProgress(*model, CADLoadStageFinishing, -1.0);
        return CADBridgeStatusOK;
    } catch (const LoadAborted& aborted) {
        return failLoad(*model, aborted.status, aborted.message);
    } catch (const std::bad_alloc&) {
        return invalid("not enough memory to read the shape data.");
    } catch (const Standard_Failure& exception) {
        // BinTools often throws with an empty message (a short read).
        const char *detail = exception.GetMessageString();
        return detail && detail[0]
            ? failLoad(*model, CADBridgeStatusImportFailed, std::string("Invalid model cache entry: ") + detail)
            : invalid("the shape data did not parse.");
    } catch (...) {
        return invalid("the shape data did not parse.");
    }
}

const char *CADBridgeCacheVersion(void) {
    static const std::string version = [] {
        char layout[160];
        std::snprintf(layout, sizeof layout, "v%zu-t%zu-f%zu-e%zu-p%zu-b%zu-s%zu",
                      sizeof(CADVertex), sizeof(CADTriangle), sizeof(CADFaceRange), sizeof(CADEdgePolyline),
                      sizeof(CADPoint3D), sizeof(CADBounds), sizeof(CADModelStats));
        return std::string(kBridgeOutputRevision) + ";occt-" + OCC_VERSION_STRING_EXT + ";" + layout;
    }();
    return version.c_str();
}
