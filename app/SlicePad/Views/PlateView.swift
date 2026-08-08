import SceneKit
import SwiftUI
import UIKit

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
        view.autoenablesDefaultLighting = true
        // Darker than the plate, so the bed reads as a surface sitting in space
        // rather than as an outline drawn on the background.
        view.backgroundColor = .systemGray5

        // Bed coordinates are Z-up; SceneKit is Y-up. One rotation on the root keeps
        // every buffer below it in the engine's own frame.
        let root = SCNNode()
        root.eulerAngles.x = -.pi / 2
        root.name = "root"
        view.scene?.rootNode.addChildNode(root)

        // SceneKit's own camera control is not used: its two-finger pan and its
        // pinch are competing recognisers, so a one-handed pinch while panning is
        // dropped, and its inertia throws the view across the plate on release.
        view.allowsCameraControl = false
        view.scene?.rootNode.addChildNode(context.coordinator.cameraNode)
        view.pointOfView = context.coordinator.cameraNode
        context.coordinator.view = view
        context.coordinator.apply()

        let orbit = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        let truck = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.truck(_:)))
        truck.minimumNumberOfTouches = 2
        truck.maximumNumberOfTouches = 2
        truck.delegate = context.coordinator
        view.addGestureRecognizer(truck)
        context.coordinator.truckGesture = truck

        let dolly = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.dolly(_:)))
        dolly.delegate = context.coordinator
        view.addGestureRecognizer(dolly)
        context.coordinator.dollyGesture = dolly

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

        // Only a newly opened model reframes. Switching between the model and the
        // layers is a change of what is drawn, not of what you are looking at, and
        // moving the camera there throws away wherever the user had put it.
        if context.coordinator.framedGeneration != geometry.modelGeneration,
           let bounds = geometry.bounds {
            context.coordinator.framedGeneration = geometry.modelGeneration
            frameCamera(context.coordinator, bed: geometry.bed, bounds: bounds)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the camera, which is a turntable: a target to look at, a distance from
    /// it, and two angles. Every gesture moves one of those four and re-derives the
    /// position, so no gesture can leave the camera somewhere the others cannot
    /// reason about.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        struct State: Equatable {
            let revision: Int
            let display: AppModel.Display
        }

        var state: State?
        var framedGeneration: Int?

        weak var view: SCNView?
        weak var truckGesture: UIPanGestureRecognizer?
        weak var dollyGesture: UIPinchGestureRecognizer?

        let cameraNode: SCNNode = {
            let camera = SCNCamera()
            camera.zFar = 5000
            let node = SCNNode()
            node.camera = camera
            return node
        }()

        // Scene space, so the -90° root rotation is already accounted for: engine
        // (x, y, z) is scene (x, z, -y).
        var target = SIMD3<Float>(0, 0, 0)
        var distance: Float = 400
        var yaw: Float = -.pi / 4
        var pitch: Float = 0.69

        /// Radians per point dragged: a full turn takes about a thousand points,
        /// which is a little over a screen width.
        private let orbitSpeed: Float = 0.006

        func apply() {
            // Never quite flat and never over the top: past either, a turntable
            // stops describing what the fingers are doing.
            pitch = min(max(pitch, 0.05), 1.5)
            distance = min(max(distance, 10), 3000)

            let horizontal = distance * cos(pitch)
            cameraNode.simdPosition = target + SIMD3<Float>(horizontal * sin(yaw),
                                                            distance * sin(pitch),
                                                            horizontal * cos(yaw))
            // Set from the angles rather than solved for with look(at:), which
            // orients relative to where the node already points — so each call
            // starts from the last one's answer and drift accumulates as roll.
            // Yaw and pitch place the camera, so they describe its orientation
            // exactly, and a turntable has no roll by definition.
            cameraNode.simdEulerAngles = SIMD3<Float>(-pitch, yaw, 0)
        }

        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let movement = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)

            yaw -= Float(movement.x) * orbitSpeed
            pitch += Float(movement.y) * orbitSpeed
            apply()
        }

        @objc func truck(_ gesture: UIPanGestureRecognizer) {
            guard let view, view.bounds.height > 0 else { return }
            let movement = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)

            // Scaled so the plate keeps up with the fingers: at the target's depth
            // this is how many millimetres one point of screen covers.
            let fieldOfView = Float(cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
            let perPoint = 2 * distance * tan(fieldOfView / 2) / Float(view.bounds.height)

            target += (cameraNode.simdWorldRight * -Float(movement.x)
                       + cameraNode.simdWorldUp * Float(movement.y)) * perPoint
            apply()
        }

        @objc func dolly(_ gesture: UIPinchGestureRecognizer) {
            let scale = Float(gesture.scale)
            gesture.scale = 1
            guard scale > 0 else { return }

            distance /= scale
            apply()
        }

        // The two-finger gestures are one motion as far as a hand is concerned, so
        // they have to be allowed to run together; the single-finger orbit stays
        // exclusive, or a pinch would rotate the view as well.
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gesture === truckGesture && other === dollyGesture)
                || (gesture === dollyGesture && other === truckGesture)
        }
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
            surface.firstMaterial?.diffuse.contents = UIColor.systemBackground
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
        geometry.firstMaterial?.diffuse.contents = UIColor.systemGray2
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

    private func frameCamera(_ coordinator: Coordinator, bed: [SIMD2<Float>],
                             bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        // Frame the bed, not the part. Framing the part put a 27mm object in the
        // middle of an empty view with one corner of a 350mm bed drifting past the
        // top edge — technically correct and useless, because the question a plate
        // view answers is where the thing sits on the plate. Pinch zooms in.
        var centre = (bounds.min + bounds.max) / 2
        var span = max(simd_reduce_max(bounds.max - bounds.min), 50)
        if !bed.isEmpty {
            let xs = bed.map(\.x), ys = bed.map(\.y)
            let low = SIMD2(xs.min() ?? 0, ys.min() ?? 0)
            let high = SIMD2(xs.max() ?? 0, ys.max() ?? 0)
            centre = SIMD3((low.x + high.x) / 2, (low.y + high.y) / 2, centre.z)
            span = max(high.x - low.x, high.y - low.y)
        }

        coordinator.target = SIMD3<Float>(centre.x, centre.z, -centre.y)
        coordinator.distance = span * 1.25
        // Down from the front-left, roughly the desktop's default.
        coordinator.yaw = -.pi / 4
        coordinator.pitch = 0.69
        coordinator.apply()
    }
}
