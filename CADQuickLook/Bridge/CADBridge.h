#ifndef CADBridge_h
#define CADBridge_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque owner of the imported Open CASCADE shape and all generated display data.
typedef struct CADBridgeModel CADBridgeModel;

typedef enum CADBridgeStatus {
    CADBridgeStatusOK = 0,
    CADBridgeStatusInvalidArgument = 1,
    CADBridgeStatusFileNotFound = 2,
    CADBridgeStatusUnsupportedFormat = 3,
    CADBridgeStatusImportFailed = 4,
    CADBridgeStatusMeshingFailed = 5,
    CADBridgeStatusOutOfRange = 6,
    CADBridgeStatusMeasurementFailed = 7,
    CADBridgeStatusInternalError = 8,
    /// The load was stopped through its cancel token (window closed, file replaced).
    CADBridgeStatusCancelled = 9,
    /// The load was stopped because it would exceed a memory or size limit
    /// (the token's memory budget, or the triangle/edge budget). The model
    /// is too complex to display; the error message says which limit.
    CADBridgeStatusResourceLimit = 10
} CADBridgeStatus;

typedef struct CADMeshOptions {
    /// Maximum chordal deviation in the model's units. Values <= 0 use an
    /// automatic value derived from the bounding-box diagonal.
    double linearDeflection;
    /// Maximum angular deviation in radians. Values <= 0 default to 0.15.
    double angularDeflectionRadians;
    /// Deflection used to sample exact topological edges. Values <= 0 use the
    /// mesh linear deflection.
    double edgeDeflection;
    /// Ask OCCT to mesh in parallel (0 or 1).
    uint8_t parallel;
    /// Multiplier applied to the automatic linear deflection (values <= 0
    /// mean 1). Thumbnails use a coarser mesh to load faster.
    double linearDeflectionScale;
} CADMeshOptions;

/// Stops a load in progress, and caps the memory a load may use. Tokens are
/// reference counted and independent of the model, so a host can cancel
/// from any thread while (or after) the model is destroyed.
typedef struct CADBridgeCancelToken CADBridgeCancelToken;

/// Creates a token holding one reference. `memoryBudgetBytes` is the
/// process footprint (phys_footprint) above which a load stops with
/// CADBridgeStatusResourceLimit; 0 means no memory budget. The budget also
/// scales the triangle and edge-point limits.
CADBridgeCancelToken *CADBridgeCancelTokenCreate(uint64_t memoryBudgetBytes);
/// Requests that any load using this token stop as soon as it can. Thread-safe.
void CADBridgeCancelTokenCancel(CADBridgeCancelToken *token);
/// Drops one reference.
void CADBridgeCancelTokenRelease(CADBridgeCancelToken *token);
/// Uses `token` (retained) for subsequent loads; NULL clears it.
void CADBridgeModelSetCancelToken(CADBridgeModel *model, CADBridgeCancelToken *token);

typedef enum CADLoadStage {
    CADLoadStageReading = 0,
    CADLoadStageTranslating = 1,
    CADLoadStageMeshing = 2,
    CADLoadStageBuildingMesh = 3,
    CADLoadStageSamplingEdges = 4,
    CADLoadStageFinishing = 5
} CADLoadStage;

/// Progress callback. `fraction` is 0...1, or a negative value when the stage
/// has no measurable progress. `count` is the number of items in the stage
/// (faces, edges) when known, else 0. May be invoked from worker threads.
typedef void (*CADBridgeProgressCallback)(void *context, CADLoadStage stage, double fraction, uint32_t count);

/// Installs a progress callback for subsequent loads. Pass NULL to clear.
void CADBridgeModelSetProgressCallback(CADBridgeModel *model, CADBridgeProgressCallback callback, void *context);

typedef struct CADVertex {
    float x, y, z;
    float nx, ny, nz;
} CADVertex;

typedef struct CADTriangle {
    uint32_t i0, i1, i2;
    /// Zero-based index into the face array.
    uint32_t faceIndex;
} CADTriangle;

typedef struct CADPoint3D {
    double x, y, z;
} CADPoint3D;

typedef enum CADSurfaceType {
    CADSurfaceTypeOther = 0,
    CADSurfaceTypePlane = 1,
    CADSurfaceTypeCylinder = 2,
    CADSurfaceTypeCone = 3,
    CADSurfaceTypeSphere = 4,
    CADSurfaceTypeTorus = 5
} CADSurfaceType;

/// The triangles for each face are contiguous. Empty/degenerate faces have a
/// triangleCount of zero but still have a range entry.
typedef struct CADFaceRange {
    uint32_t firstTriangle;
    uint32_t triangleCount;
    /// Exact OCCT B-Rep surface area in squared model units, or -1 until
    /// CADBridgeModelFaceArea() computes it on demand.
    double exactArea;
    /// Analytic classification of the underlying surface (CADSurfaceType).
    uint8_t surfaceType;
    /// Cylinder/sphere radius, cone reference radius, torus major radius.
    double radius;
    /// Cylinder/cone: height of the trimmed face along its axis. 0 otherwise.
    double extent;
    /// Plane: the outward unit normal (face orientation applied).
    /// Cylinder/cone/torus: the unit axis direction. Zero otherwise.
    CADPoint3D axisDirection;
    /// STEP colour (sRGB 0...1) from the face, its body or its assembly
    /// instance; valid when hasColor is 1.
    float red, green, blue;
    uint8_t hasColor;
} CADFaceRange;

typedef enum CADCurveType {
    CADCurveTypeOther = 0,
    CADCurveTypeLine = 1,
    CADCurveTypeCircle = 2
} CADCurveType;

/// An edge references a contiguous range in CADBridgeModelPolylinePoints().
typedef struct CADEdgePolyline {
    uint32_t firstPoint;
    uint32_t pointCount;
    /// Exact OCCT curve length in model units (not the polyline length), or
    /// -1 until CADBridgeModelEdgeLength() computes it on demand.
    double exactLength;
    /// 1 when the underlying exact OCCT curve is a circle or circular arc.
    uint8_t isCircular;
    /// Exact circle diameter in model units, or 0 for non-circular edges.
    double exactDiameter;
    /// 1 when the two faces meeting at this edge are tangent across it (a
    /// fillet boundary, a cylinder seam): a "tangent edge" that CAD viewers
    /// usually draw faintly or not at all. 0 for sharp and free edges.
    uint8_t isTangent;
    /// Analytic classification of the underlying curve (CADCurveType).
    uint8_t curveType;
    /// 1 when the edge is never drawn as a line: a seam, where a periodic
    /// surface (cylinder, torus...) meets itself, or a degenerated edge (the
    /// collapsed pole of a sphere or cone). Kept in the table so edge indices
    /// and measurement stay valid. Occupies padding, so the size is unchanged.
    uint8_t isHidden;
    /// Line: unit direction. Circle: unit axis (normal of the circle's plane).
    CADPoint3D direction;
} CADEdgePolyline;

typedef struct CADBounds {
    CADPoint3D minimum;
    CADPoint3D maximum;
    uint8_t isValid;
} CADBounds;

typedef struct CADModelStats {
    uint32_t faceCount;
    uint32_t edgeCount;
    uint32_t vertexCount;
    uint32_t shellCount;
    uint32_t solidCount;
    uint32_t triangleCount;
    double totalEdgeLength;
    double surfaceArea;
    double volume;
} CADModelStats;

typedef struct CADFaceDistance {
    double distance;
    CADPoint3D pointOnFaceA;
    CADPoint3D pointOnFaceB;
} CADFaceDistance;

typedef enum CADMeasureEntityKind {
    /// An arbitrary point; `point` is used and `index` ignored.
    CADMeasureEntityKindPoint = 0,
    /// A B-Rep edge; `index` is zero-based into CADBridgeModelEdges().
    CADMeasureEntityKindEdge = 1,
    /// A B-Rep face; `index` is zero-based into CADBridgeModelFaceRanges().
    CADMeasureEntityKindFace = 2
} CADMeasureEntityKind;

typedef struct CADMeasureEntity {
    uint8_t kind;
    uint32_t index;
    CADPoint3D point;
} CADMeasureEntity;

/// Sensible interactive-view defaults. The linear and edge deflections are
/// automatic (0); angular deflection is 0.15 radians; parallel is enabled.
CADMeshOptions CADBridgeDefaultMeshOptions(void);

CADBridgeModel *CADBridgeModelCreate(void);
void CADBridgeModelDestroy(CADBridgeModel *model);

/// Frees the vertex, triangle and polyline buffers and the tessellation that
/// Open CASCADE attached to the shape, once the host has copied what it
/// needs. After this call CADBridgeModelVertices(), CADBridgeModelTriangles()
/// and CADBridgeModelPolylinePoints() return NULL with a count of zero, but
/// the face/edge tables, bounds, stats and all measurement calls keep working.
void CADBridgeModelReleaseDisplayData(CADBridgeModel *model);

/// Returns freed malloc pages to the kernel. Called automatically after
/// CADBridgeModelReleaseDisplayData() and CADBridgeModelDestroy().
void CADBridgeTrimMemory(void);

/// Serialises the model's exact B-Rep (without tessellation) for the model
/// cache, in Open CASCADE's binary format. Works before or after
/// CADBridgeModelReleaseDisplayData(). Returns a buffer the caller frees with
/// CADBridgeFree(), or NULL (no shape, e.g. STL, or a serialisation error).
uint8_t *CADBridgeModelCopyShapeData(const CADBridgeModel *model, size_t *outLength);

/// Frees memory returned by the bridge (CADBridgeModelCopyShapeData).
void CADBridgeFree(void *data);

/// Rebuilds a loaded model from a cache entry: the B-Rep bytes from
/// CADBridgeModelCopyShapeData() plus the face and edge tables, bounds and
/// stats saved with them. Face/edge order is the bridge's enumeration order,
/// so measurement indices stay valid. Returns CADBridgeStatusImportFailed if
/// the bytes do not parse or the shape's face/edge counts differ from the
/// tables (a corrupt or incompatible entry; the host should delete it and
/// load the file normally). The display arrays (vertices, triangles,
/// polylines) stay empty; the host keeps its own copies.
CADBridgeStatus CADBridgeModelRestore(CADBridgeModel *model,
                                      const uint8_t *shapeData, size_t shapeLength,
                                      const CADFaceRange *faceRanges, size_t faceCount,
                                      const CADEdgePolyline *edges, size_t edgeCount,
                                      CADBounds bounds, CADModelStats stats);

/// Identifies everything that determines the bridge's output for a given
/// file and options (bridge output revision, Open CASCADE version, struct
/// layouts). Cache keys include it so a changed bridge never reads an old entry.
const char *CADBridgeCacheVersion(void);

/// Loads and tessellates STEP/STP, IGES/IGS, BREP, or STL. Loading another file
/// replaces all prior shape and display data. The path must be UTF-8.
CADBridgeStatus CADBridgeModelLoad(CADBridgeModel *model,
                                   const char *pathUTF8,
                                   CADMeshOptions options);

/// Borrowed UTF-8 string, valid until the next load or model destruction.
const char *CADBridgeModelLastError(const CADBridgeModel *model);

const CADVertex *CADBridgeModelVertices(const CADBridgeModel *model);
size_t CADBridgeModelVertexCount(const CADBridgeModel *model);

const CADTriangle *CADBridgeModelTriangles(const CADBridgeModel *model);
size_t CADBridgeModelTriangleCount(const CADBridgeModel *model);

const CADFaceRange *CADBridgeModelFaceRanges(const CADBridgeModel *model);
size_t CADBridgeModelFaceCount(const CADBridgeModel *model);

const CADPoint3D *CADBridgeModelPolylinePoints(const CADBridgeModel *model);
size_t CADBridgeModelPolylinePointCount(const CADBridgeModel *model);

const CADEdgePolyline *CADBridgeModelEdges(const CADBridgeModel *model);
size_t CADBridgeModelEdgeCount(const CADBridgeModel *model);

CADBounds CADBridgeModelBounds(const CADBridgeModel *model);
CADModelStats CADBridgeModelStats(const CADBridgeModel *model);

/// Exact surface area of a face (zero-based index), computed lazily and cached.
CADBridgeStatus CADBridgeModelFaceArea(CADBridgeModel *model, uint32_t faceIndex, double *outArea);

/// Exact curve length of an edge (zero-based index), computed lazily and cached.
CADBridgeStatus CADBridgeModelEdgeLength(CADBridgeModel *model, uint32_t edgeIndex, double *outLength);

/// Computes the exact minimum distance between two B-Rep faces. Face indices
/// are zero-based and correspond to CADTriangle.faceIndex/CADFaceRange.
CADBridgeStatus CADBridgeModelMeasureFaceDistance(CADBridgeModel *model,
                                                  uint32_t faceA,
                                                  uint32_t faceB,
                                                  CADFaceDistance *result);

/// Computes the exact minimum distance between any two entities (points,
/// edges, faces in any combination). `pointOnFaceA`/`pointOnFaceB` are the
/// closest points on the first and second entity.
CADBridgeStatus CADBridgeModelMeasureDistance(CADBridgeModel *model,
                                              CADMeasureEntity a,
                                              CADMeasureEntity b,
                                              CADFaceDistance *result);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* CADBridge_h */
