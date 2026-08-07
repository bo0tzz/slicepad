import SceneKit
import SwiftUI

/// The plate: bed outline, the model as a solid, and after a slice the toolpath as
/// stacked layers. SceneKit rather than RealityKit — this is a CAD-ish view of a
/// static scene, and SCNGeometry takes packed vertex buffers directly, which is the
/// form the engine already hands over.
struct PlateView: UIViewRepresentable {
    let geometry: PlateGeometry
    let display: AppModel.Display

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemGroupedBackground
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true

        // Bed coordinates are Z-up; SceneKit is Y-up. One rotation on the root keeps
        // every buffer below it in the engine's own frame.
        let root = SCNNode()
        root.eulerAngles.x = -.pi / 2
        root.name = "root"
        view.scene?.rootNode.addChildNode(root)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let root = view.scene?.rootNode.childNode(withName: "root", recursively: false) else { return }

        // SwiftUI re-runs this for any state change at all, progress ticks included.
        let state = Coordinator.State(revision: geometry.revision, display: display)
        guard context.coordinator.state != state else { return }
        context.coordinator.state = state

        root.childNodes.forEach { $0.removeFromParentNode() }

        if !geometry.bed.isEmpty {
            root.addChildNode(bedNode(geometry.bed))
        }

        switch display {
        case .model:
            if let node = solidNode(geometry.triangles) { root.addChildNode(node) }
        case .layers:
            if let node = toolpathNode(geometry.toolpath) {
                root.addChildNode(node)
            } else if let node = solidNode(geometry.triangles) {
                root.addChildNode(node)
            }
        }

        if context.coordinator.framedGeneration != geometry.modelGeneration,
           let bounds = geometry.bounds {
            context.coordinator.framedGeneration = geometry.modelGeneration
            frameCamera(view, bed: geometry.bed, bounds: bounds)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        struct State: Equatable {
            let revision: Int
            let display: AppModel.Display
        }

        var state: State?
        var framedGeneration: Int?
    }

    // MARK: Nodes

    private func bedNode(_ outline: [SIMD2<Float>]) -> SCNNode {
        let node = SCNNode()

        // A surface as well as an outline. Four thin lines around a 350mm square
        // read as nothing much; a plate you can see the part standing on reads as
        // a bed. Its bounding rectangle is enough — printers whose bed is not a
        // rectangle would only lose a little of the corner shading.
        let xs = outline.map(\.x), ys = outline.map(\.y)
        if let lowX = xs.min(), let highX = xs.max(),
           let lowY = ys.min(), let highY = ys.max() {
            let surface = SCNPlane(width: CGFloat(highX - lowX), height: CGFloat(highY - lowY))
            surface.firstMaterial?.diffuse.contents = UIColor.secondarySystemBackground
            surface.firstMaterial?.isDoubleSided = true
            surface.firstMaterial?.lightingModel = .constant
            let surfaceNode = SCNNode(geometry: surface)
            // Just below the bed plane, so it does not fight with a model sitting
            // exactly at z = 0.
            surfaceNode.position = SCNVector3((lowX + highX) / 2, (lowY + highY) / 2, -0.05)
            node.addChildNode(surfaceNode)
        }

        var vertices: [SCNVector3] = []
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            vertices.append(SCNVector3(a.x, a.y, 0))
            vertices.append(SCNVector3(b.x, b.y, 0))
        }

        let source = SCNGeometrySource(vertices: vertices)
        let indices = (0 ..< Int32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemGray
        geometry.firstMaterial?.lightingModel = .constant
        node.addChildNode(SCNNode(geometry: geometry))
        return node
    }

    private func solidNode(_ triangles: [SIMD3<Float>]) -> SCNNode? {
        guard !triangles.isEmpty else { return nil }

        let vertices = triangles.map { SCNVector3($0.x, $0.y, $0.z) }
        // Per-face normals from the winding: the engine hands over triangle soup with
        // no normals, and flat shading is the honest look for a printed part anyway.
        var normals: [SCNVector3] = []
        normals.reserveCapacity(vertices.count)
        for i in stride(from: 0, to: triangles.count, by: 3) {
            let n = simd_normalize(simd_cross(triangles[i + 1] - triangles[i],
                                              triangles[i + 2] - triangles[i]))
            let normal = n.x.isNaN ? SCNVector3(0, 0, 1) : SCNVector3(n.x, n.y, n.z)
            normals.append(contentsOf: [normal, normal, normal])
        }

        let element = SCNGeometryElement(indices: (0 ..< Int32(vertices.count)).map { $0 },
                                         primitiveType: .triangles)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices),
                      SCNGeometrySource(normals: normals)],
            elements: [element]
        )
        geometry.firstMaterial?.diffuse.contents = UIColor.systemOrange
        geometry.firstMaterial?.isDoubleSided = true
        return SCNNode(geometry: geometry)
    }

    private func toolpathNode(_ segments: [SIMD3<Float>]) -> SCNNode? {
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

    private func frameCamera(_ view: SCNView, bed: [SIMD2<Float>],
                             bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        // Replacing rather than adding: this runs again for each model opened, and
        // scene roots accumulate whatever you hang off them.
        view.scene?.rootNode.childNode(withName: "camera", recursively: false)?
            .removeFromParentNode()

        let camera = SCNCamera()
        camera.zFar = 5000
        let node = SCNNode()
        node.name = "camera"
        node.camera = camera

        // Frame the bed, not the part. Framing the part put a 27mm object in the
        // middle of an empty view with one corner of a 350mm bed drifting past the
        // top edge — technically correct and useless, because the question a plate
        // view answers is where the thing sits on the plate. Pinch still zooms in.
        var centre = (bounds.min + bounds.max) / 2
        var span = max(simd_reduce_max(bounds.max - bounds.min), 50)
        if !bed.isEmpty {
            let xs = bed.map(\.x), ys = bed.map(\.y)
            let low = SIMD2(xs.min() ?? 0, ys.min() ?? 0)
            let high = SIMD2(xs.max() ?? 0, ys.max() ?? 0)
            centre = SIMD3((low.x + high.x) / 2, (low.y + high.y) / 2, centre.z)
            span = max(high.x - low.x, high.y - low.y)
        }
        let distance = Double(span) * 1.4

        // The camera hangs off the scene root, but the geometry sits under a node
        // rotated to make Z up — so the target has to be converted: engine (x,y,z)
        // becomes scene (x, z, -y).
        let target = SCNVector3(centre.x, centre.z, -centre.y)

        // Looking down from the front-left, roughly the desktop's default.
        node.position = SCNVector3(Double(target.x) - distance * 0.6,
                                   Double(target.y) + distance * 0.7,
                                   Double(target.z) + distance * 0.6)
        view.pointOfView = node
        view.scene?.rootNode.addChildNode(node)
        node.look(at: target)
    }
}
