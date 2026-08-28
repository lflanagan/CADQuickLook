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
    CADBridgeStatusInternalError = 8
} CADBridgeStatus;

typedef struct CADMeshOptions {
    /// Maximum chordal deviation in the model's units. Values <= 0 use an
    /// automatic value derived from the bounding-box diagonal.
    double linearDeflection;
    /// Maximum angular deviation in radians. Values <= 0 default to 0.35.
    double angularDeflectionRadians;
    /// Deflection used to sample exact topological edges. Values <= 0 use the
    /// mesh linear deflection.
    double edgeDeflection;
    /// Ask OCCT to mesh in parallel (0 or 1).
    uint8_t parallel;
} CADMeshOptions;

typedef struct CADVertex {
    float x, y, z;
    float nx, ny, nz;
} CADVertex;

typedef struct CADTriangle {
    uint32_t i0, i1, i2;
    /// Zero-based index into the face array.
    uint32_t faceIndex;
} CADTriangle;

/// The triangles for each face are contiguous. Empty/degenerate faces have a
/// triangleCount of zero but still have a range entry.
typedef struct CADFaceRange {
    uint32_t firstTriangle;
    uint32_t triangleCount;
    /// Exact OCCT B-Rep surface area in squared model units.
    double exactArea;
} CADFaceRange;

typedef struct CADPoint3D {
    double x, y, z;
} CADPoint3D;

/// An edge references a contiguous range in CADBridgeModelPolylinePoints().
typedef struct CADEdgePolyline {
    uint32_t firstPoint;
    uint32_t pointCount;
    /// Exact OCCT curve length in model units (not the polyline length).
    double exactLength;
    /// 1 when the underlying exact OCCT curve is a circle or circular arc.
    uint8_t isCircular;
    /// Exact circle diameter in model units, or 0 for non-circular edges.
    double exactDiameter;
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

/// Sensible interactive-view defaults. The linear and edge deflections are
/// automatic (0); angular deflection is 0.35 radians; parallel is enabled.
CADMeshOptions CADBridgeDefaultMeshOptions(void);

CADBridgeModel *CADBridgeModelCreate(void);
void CADBridgeModelDestroy(CADBridgeModel *model);

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

/// Computes the exact minimum distance between two B-Rep faces. Face indices
/// are zero-based and correspond to CADTriangle.faceIndex/CADFaceRange.
CADBridgeStatus CADBridgeModelMeasureFaceDistance(CADBridgeModel *model,
                                                  uint32_t faceA,
                                                  uint32_t faceB,
                                                  CADFaceDistance *result);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* CADBridge_h */
