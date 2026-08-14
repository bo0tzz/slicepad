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

    /// The local frame of one segment, named as the desktop names it: forward along
    /// the path, right across it, up out of it.
    private struct Axes {
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    /// Same derivation as GCodeViewer's segment_local_axes. `up` comes out of the
    /// other two rather than being the world's up, so a segment that climbs leans its
    /// section with it instead of shearing.
    private static func axes(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Axes? {
        let along = end - start
        let length = simd_length(along)
        guard length > 1e-5 else { return nil }
        let forward = along / length
        let across = simd_cross(forward, SIMD3<Float>(0, 0, 1))
        // Zero for a move straight up or down, which a path does not contain: those
        // are travels, and travels are not extrusions.
        guard simd_length(across) > 1e-5 else { return nil }
        let right = simd_normalize(across)
        return Axes(forward: forward, right: right, up: simd_cross(right, forward))
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
        // A ring of four per corner rather than eight per segment, since neighbours
        // in a path now share one.
        vertices.reserveCapacity(segments * 5)

        func shows(_ segment: Int) -> Bool {
            visible.map { $0.contains(plate.layers[segment]) } ?? true
        }

        /// Whether two segments are one path: the same kind of extrusion on the same
        /// layer, the second starting where the first stopped.
        func joins(_ first: Int, _ second: Int) -> Bool {
            guard shows(second),
                  plate.roles[first] == plate.roles[second],
                  plate.layers[first] == plate.layers[second],
                  simd_distance(plate.toolpath[first * 2 + 1],
                                plate.toolpath[second * 2]) < 1e-4
            else { return false }
            // A doubling-back leaves the two rights cancelling, and averaging them
            // gives a section with no width at all. Rare enough to just break the run.
            guard let before = axes(from: plate.toolpath[first * 2],
                                    to: plate.toolpath[first * 2 + 1]),
                  let after = axes(from: plate.toolpath[second * 2],
                                   to: plate.toolpath[second * 2 + 1])
            else { return false }
            return simd_length(before.right + after.right) > 1e-3
        }

        /// One ring of four vertices about a point, with the normals pointing out of
        /// each. The desktop's cross_section, which shades like a rounded bead for
        /// four vertices rather than the dozens a real tube would need.
        func ring(at point: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                  width: Float, height: Float) {
            let across = right * (width / 2)
            let above = up * (height / 2)
            for (offset, normal) in [(across, right), (above, up),
                                     (-across, -right), (-above, -up)] {
                let at = point + offset
                vertices.append(SCNVector3(at.x, at.y, at.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }

        var segment = 0
        while segment < segments {
            guard shows(segment), let first = axes(from: plate.toolpath[segment * 2],
                                                  to: plate.toolpath[segment * 2 + 1])
            else { segment += 1; continue }

            // How far this path runs before it turns into something else.
            var last = segment
            while last + 1 < segments, joins(last, last + 1) { last += 1 }

            let base = Int32(vertices.count)
            ring(at: plate.toolpath[segment * 2], right: first.right, up: first.up,
                 width: plate.widths[segment], height: plate.heights[segment])

            // One shared ring per corner, turned to the average of the two segments
            // meeting there — the desktop's corner_cross_section. Two independent
            // ends butted together instead is what made a curve look like a pile of
            // overlapping beads rather than one strand.
            for corner in segment ..< last {
                let next = corner + 1
                guard let before = axes(from: plate.toolpath[corner * 2],
                                        to: plate.toolpath[corner * 2 + 1]),
                      let after = axes(from: plate.toolpath[next * 2],
                                       to: plate.toolpath[next * 2 + 1])
                else { continue }
                let right = simd_normalize(before.right + after.right)
                ring(at: plate.toolpath[corner * 2 + 1], right: right, up: before.up,
                     width: (plate.widths[corner] + plate.widths[next]) / 2,
                     height: (plate.heights[corner] + plate.heights[next]) / 2)
            }

            if let end = axes(from: plate.toolpath[last * 2], to: plate.toolpath[last * 2 + 1]) {
                ring(at: plate.toolpath[last * 2 + 1], right: end.right, up: end.up,
                     width: plate.widths[last], height: plate.heights[last])
            }

            // Four sides between each pair of rings, and a lid on each end: an open
            // tube shows its own inside where a path stops.
            let rings = (Int32(vertices.count) - base) / 4
            // Accumulated for this path and appended once. Reading the role's whole
            // array out, growing it and putting it back copies every index written so
            // far, on every path — which is quadratic in a print of any size.
            var indices: [Int32] = []
            for step in 0 ..< max(rings - 1, 0) {
                let here = base + step * 4, there = here + 4
                for side in Int32(0) ..< 4 {
                    let next = (side + 1) % 4
                    indices += [here + side, there + side, there + next,
                                here + side, there + next, here + next]
                }
            }
            if rings > 0 {
                for cap in [base, base + (rings - 1) * 4] {
                    indices += [cap, cap + 1, cap + 2, cap, cap + 2, cap + 3]
                }
            }
            indicesByRole[plate.roles[segment], default: []].append(contentsOf: indices)

            segment = last + 1
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
            // Blinn rather than lambert for the sake of one thing: a highlight along
            // the top of each bead. Diffuse shading alone gives two beads lying side
            // by side the same four brightnesses, so a field of them reads as one
            // surface; the highlight is what separates them into strands.
            //
            // Tight and dim, as the desktop has it: `pow(..., 20.0)` at 0.125 * 0.6.
            // SceneKit multiplies the material's specular by the light's intensity,
            // and only the top light at 0.48 is meant to produce one, so 0.16 there
            // arrives as the 0.075 the shader adds.
            material.lightingModel = .blinn
            material.specular.contents = UIColor(white: 0.16, alpha: 1)
            material.shininess = 20
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
