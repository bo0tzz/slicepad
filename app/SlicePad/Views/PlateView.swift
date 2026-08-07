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
        return SCNNode(geometry: geometry)
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

        let centre = (bounds.min + bounds.max) / 2
        let span = max(simd_reduce_max(bounds.max - bounds.min), 50)
        let distance = Double(span) * 2.5

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
