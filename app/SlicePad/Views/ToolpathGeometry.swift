import SceneKit
import UIKit

/// Builds the layer view: every extrusion drawn at the width and height the
/// slicer planned for it, coloured by what it is.
///
/// The cross-section is a diamond — a point left and right at half the width, one
/// above and below at half the height — which is what the desktop's preview uses.
/// It is not what a real extrusion looks like in section, but with the normals
/// pointing outwards from each of the four points it shades like a rounded bead,
/// and it costs four vertices per end rather than the dozens a swept tube needs.
enum ToolpathGeometry {
    /// Roughly the desktop's palette, and chosen to survive being seen in a mass:
    /// the two wall types have to be told apart at a glance, since that is the
    /// distinction anyone is actually looking for.
    static func colour(for role: UInt8) -> UIColor {
        switch role {
        case 1: return UIColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1)   // outer wall
        case 2: return UIColor(red: 0.98, green: 0.75, blue: 0.30, alpha: 1)   // inner wall
        case 3: return UIColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 1)   // infill
        case 4: return UIColor(red: 0.60, green: 0.70, blue: 0.45, alpha: 1)   // solid infill
        case 5: return UIColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1)   // bridge
        case 6: return UIColor(red: 0.45, green: 0.70, blue: 0.70, alpha: 1)   // support
        case 7: return UIColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)   // skirt or brim
        default: return UIColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1)
        }
    }

    /// `layers` limits what is drawn, so a range control shows the print part-built.
    /// Nil draws everything.
    static func node(_ plate: PlateGeometry, layers visible: ClosedRange<UInt32>?) -> SCNNode? {
        let segments = plate.toolpath.count / 2
        guard segments > 0 else { return nil }
        // Anything missing means an engine that reported coordinates without the
        // description; drawing centre lines is a better answer than drawing nothing.
        guard plate.roles.count == segments, plate.widths.count == segments,
              plate.heights.count == segments, plate.layers.count == segments
        else { return lineNode(plate.toolpath) }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        // Indices per role rather than a colour per vertex. SceneKit's vertex
        // colours need the material to agree about how they are consumed, and got
        // this drawn in the dark; a geometry element per role with its own material
        // is the plain way to say the same thing.
        var indicesByRole: [UInt8: [Int32]] = [:]
        vertices.reserveCapacity(segments * 8)

        for segment in 0 ..< segments {
            if let visible, !visible.contains(plate.layers[segment]) { continue }

            let start = plate.toolpath[segment * 2]
            let end = plate.toolpath[segment * 2 + 1]
            let along = end - start
            let length = simd_length(along)
            guard length > 1e-5 else { continue }

            // The section is flat on the bed and upright in Z, so "sideways" is the
            // path turned a quarter turn in the bed plane. A path climbing in Z —
            // there are few — leans its section with it, which is close enough at
            // the width of one extrusion.
            let direction = along / length
            var sideways = SIMD3<Float>(-direction.y, direction.x, 0)
            let sidewaysLength = simd_length(sideways)
            sideways = sidewaysLength > 1e-5 ? sideways / sidewaysLength : SIMD3<Float>(1, 0, 0)
            let up = SIMD3<Float>(0, 0, 1)

            let halfWidth = plate.widths[segment] / 2
            let halfHeight = plate.heights[segment] / 2
            let base = Int32(vertices.count)

            for point in [start, end] {
                for (offset, normal) in [(sideways * halfWidth, sideways),
                                         (up * halfHeight, up),
                                         (-sideways * halfWidth, -sideways),
                                         (-up * halfHeight, -up)] {
                    let at = point + offset
                    vertices.append(SCNVector3(at.x, at.y, at.z))
                    normals.append(SCNVector3(normal.x, normal.y, normal.z))
                }
            }

            // Four sides joining the two diamonds, each two triangles.
            var indices = indicesByRole[plate.roles[segment], default: []]
            for side in Int32(0) ..< 4 {
                let next = (side + 1) % 4
                indices += [base + side, base + 4 + side, base + 4 + next,
                            base + side, base + 4 + next, base + next]
            }
            indicesByRole[plate.roles[segment]] = indices
        }

        guard !indicesByRole.isEmpty else { return nil }

        let roles = indicesByRole.keys.sorted()
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices),
                      SCNGeometrySource(normals: normals)],
            elements: roles.map {
                SCNGeometryElement(indices: indicesByRole[$0] ?? [], primitiveType: .triangles)
            }
        )
        geometry.materials = roles.map { role in
            let material = SCNMaterial()
            material.diffuse.contents = colour(for: role)
            material.lightingModel = .lambert
            material.isDoubleSided = true
            return material
        }
        return SCNNode(geometry: geometry)
    }

    /// The fallback, and what the view used to draw everywhere.
    private static func lineNode(_ segments: [SIMD3<Float>]) -> SCNNode? {
        guard !segments.isEmpty else { return nil }
        let vertices = segments.map { SCNVector3($0.x, $0.y, $0.z) }
        let element = SCNGeometryElement(indices: (0 ..< Int32(vertices.count)).map { $0 },
                                         primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [element])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemTeal
        geometry.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: geometry)
    }
}
