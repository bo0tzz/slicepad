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
    /// Which layers the layer view shows; nil is all of them.
    var visibleLayers: ClosedRange<UInt32>?
    /// Where the object was dragged to, in bed millimetres, once the finger lifts.
    var onMove: ((Double, Double) -> Void)?
    /// The object's rotation about the bed's up axis, in degrees, and where the
    /// ring left it.
    var rotationDegrees: Double = 0
    var onRotate: ((Double) -> Void)?

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
        context.coordinator.onMove = onMove
        context.coordinator.onRotate = onRotate
        context.coordinator.objectOffset = geometry.offset
        context.coordinator.rotationDegrees = rotationDegrees
        guard let root = view.scene?.rootNode.childNode(withName: "root", recursively: false) else { return }

        // SwiftUI re-runs this for any state change at all, progress ticks included.
        let state = Coordinator.State(revision: geometry.revision, display: display,
                                      layers: visibleLayers)
        guard context.coordinator.state != state else { return }
        context.coordinator.state = state

        root.childNodes.forEach { $0.removeFromParentNode() }

        if !geometry.bed.isEmpty {
            root.addChildNode(bedNode(geometry.bed))
        }

        switch display {
        case .model:
            if let node = solidNode(geometry.triangles) {
                node.name = "model"
                root.addChildNode(node)
                context.coordinator.modelNode = node

                // Handles only where they mean something: there is nothing to
                // place once the part has been sliced into a toolpath.
                if let bounds = geometry.bounds {
                    let centre = SIMD2<Float>((bounds.min.x + bounds.max.x) / 2,
                                              (bounds.min.y + bounds.max.y) / 2)
                    let gizmo = gizmoNode(centre: centre)
                    root.addChildNode(gizmo)
                    context.coordinator.gizmo = gizmo
                    context.coordinator.gizmoCentre = centre
                    context.coordinator.updateHandleScale()
                }
            }
        case .layers:
            if let node = ToolpathGeometry.node(geometry, layers: visibleLayers) {
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
            let layers: ClosedRange<UInt32>?
        }

        var state: State?
        var framedGeneration: Int?

        weak var view: SCNView?
        var onMove: ((Double, Double) -> Void)?
        var onRotate: ((Double) -> Void)?
        var objectOffset = SIMD2<Float>(0, 0)
        var rotationDegrees: Double = 0

        weak var modelNode: SCNNode?
        weak var gizmo: SCNNode?
        var gizmoCentre = SIMD2<Float>(0, 0)

        /// What the one-finger gesture is doing for its lifetime, decided when it
        /// starts: a handle if it began on one, the part if it began on that, and
        /// otherwise the camera — so a drag from empty plate still turns the view.
        private enum Handle { case body, axisX, axisY, rotate }
        private var handle: Handle?
        private var startBed = SIMD2<Float>(0, 0)
        private var startAngle: Float = 0

        /// The gizmo is built at unit size and scaled to a fixed size on screen: a
        /// handle that shrinks with the part is unusable at the zoom where placing
        /// things is hardest.
        private(set) var handleScale: Float = 1
        var ringRadius: Float { 0.8 * handleScale }

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
            // Clamping the pitch is not enough to stay above the plate, because
            // panning moves what the camera looks at: raise the target far enough
            // and the camera passes under the bed, where every surface faces away
            // from the light and the scene goes black. There is no view of a print
            // from underneath the bed worth having.
            target.y = max(target.y, 0)

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
            updateHandleScale()
        }

        /// Kept a constant size on screen, so the handles neither shrink out of
        /// reach when the whole bed is in view nor swamp the part up close.
        func updateHandleScale() {
            guard let view, view.bounds.height > 0 else { return }
            let fieldOfView = Float(cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
            let perPoint = 2 * distance * tan(fieldOfView / 2) / Float(view.bounds.height)
            handleScale = perPoint * 90
            gizmo?.simdScale = SIMD3<Float>(repeating: handleScale)
        }

        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)

            if gesture.state == .began {
                handle = grabbed(at: location)
                startBed = bedPoint(at: location) ?? SIMD2<Float>(0, 0)
                startAngle = angle(at: location) ?? 0
            }

            if let handle {
                drag(handle, gesture)
                if gesture.state == .ended || gesture.state == .cancelled {
                    self.handle = nil
                }
                gesture.setTranslation(.zero, in: view)
                return
            }

            let movement = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)

            yaw -= Float(movement.x) * orbitSpeed
            pitch += Float(movement.y) * orbitSpeed
            apply()
        }

        private func grabbed(at location: CGPoint) -> Handle? {
            guard let view else { return nil }
            // Every result rather than the nearest: the handles are drawn over the
            // part, so a touch near one lands on both and the handle has to win.
            let hits = view.hitTest(location,
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                guard let name = hit.node.name else { continue }
                if name == "gizmo.x" { return .axisX }
                if name == "gizmo.y" { return .axisY }
                if name == "gizmo.ring" { return .rotate }
            }
            return hits.contains(where: { $0.node.name == "model" }) ? .body : nil
        }

        /// Moves the nodes while the finger is down and tells the engine once, when
        /// it lifts. Re-transforming the mesh for every touch event would drag a
        /// whole model's triangles across the ABI several times a second.
        private func drag(_ handle: Handle, _ gesture: UIPanGestureRecognizer) {
            guard let view, let modelNode else { return }
            let location = gesture.location(in: view)
            let finished = gesture.state == .ended || gesture.state == .cancelled

            if handle == .rotate {
                guard let now = angle(at: location), let point = bedPoint(at: location) else { return }
                // Snapped at the ring, free beyond it. The arc a finger covers per
                // degree grows with the radius, so the gesture is coarse where it
                // starts and fine where there is room — and there is no modifier to
                // discover.
                let free = simd_length(point - gizmoCentre) > ringRadius * 2
                var absolute = rotationDegrees + Double(now - startAngle) * 180 / .pi
                if !free {
                    absolute = (absolute / 15).rounded() * 15
                }
                modelNode.simdTransform =
                    Self.rotation(Float((absolute - rotationDegrees) * .pi / 180), about: gizmoCentre)
                if finished {
                    onRotate?(Self.normalised(absolute))
                }
                return
            }

            guard let now = bedPoint(at: location) else { return }
            var delta = now - startBed
            if handle == .axisX { delta.y = 0 }
            if handle == .axisY { delta.x = 0 }

            // Inside the root node the axes are the bed's own, which is why this is
            // (x, y, 0) rather than the scene's (x, 0, -y).
            modelNode.simdPosition = SIMD3<Float>(delta.x, delta.y, 0)
            gizmo?.simdPosition = SIMD3<Float>(gizmoCentre.x + delta.x, gizmoCentre.y + delta.y, 0)
            if finished {
                onMove?(Double(objectOffset.x + delta.x), Double(objectOffset.y + delta.y))
            }
        }

        /// Where the touch sits around the gizmo, in the bed's plane.
        private func angle(at location: CGPoint) -> Float? {
            guard let point = bedPoint(at: location) else { return nil }
            let arm = point - gizmoCentre
            guard simd_length(arm) > 1e-4 else { return nil }
            return atan2(arm.y, arm.x)
        }

        private static func rotation(_ radians: Float, about centre: SIMD2<Float>) -> simd_float4x4 {
            let pivot = SIMD3<Float>(centre.x, centre.y, 0)
            let spin = simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(0, 0, 1)))
            return translation(pivot) * spin * translation(-pivot)
        }

        private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
            var matrix = matrix_identity_float4x4
            matrix.columns.3 = SIMD4<Float>(offset.x, offset.y, offset.z, 1)
            return matrix
        }

        /// The control this feeds binds to -180...180, so a ring turned past the end
        /// has to come back around rather than run off it.
        private static func normalised(_ degrees: Double) -> Double {
            var value = degrees.truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value <= -180 { value += 360 }
            return value
        }

        /// Where a screen point lands on the bed, in engine millimetres. Taken by
        /// intersecting the ray through that point with the bed plane rather than
        /// scaling the finger's movement, so the part stays under the finger at any
        /// angle and any zoom.
        private func bedPoint(at location: CGPoint) -> SIMD2<Float>? {
            guard let view else { return nil }
            let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
            let origin = SIMD3<Float>(near.x, near.y, near.z)
            let direction = SIMD3<Float>(far.x, far.y, far.z) - origin
            guard abs(direction.y) > 1e-6 else { return nil }

            // The bed is the plane y = 0 in scene space, and engine (x, y) is scene
            // (x, -z).
            let t = -origin.y / direction.y
            guard t > 0 else { return nil }
            let hit = origin + direction * t
            return SIMD2<Float>(hit.x, -hit.z)
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

    /// Handles for placing the part: an arrow along each bed axis and a ring for
    /// turning it. Built at unit size, because the coordinator scales the whole
    /// thing to a fixed size on screen.
    private func gizmoNode(centre: SIMD2<Float>) -> SCNNode {
        let node = SCNNode()
        node.simdPosition = SIMD3<Float>(centre.x, centre.y, 0)
        // Warm across, cool away: the pair reads as a pair, and neither is the
        // orange of the part they sit on.
        node.addChildNode(axisHandle(named: "gizmo.x", colour: .systemRed, alongX: true))
        node.addChildNode(axisHandle(named: "gizmo.y", colour: .systemBlue, alongX: false))
        node.addChildNode(rotationHandle())
        return node
    }

    private func axisHandle(named name: String, colour: UIColor, alongX: Bool) -> SCNNode {
        let node = SCNNode()

        func part(_ geometry: SCNGeometry, at height: Float) -> SCNNode {
            geometry.firstMaterial?.diffuse.contents = colour
            geometry.firstMaterial?.lightingModel = .constant
            // Drawn over the part rather than inside it: a handle hidden by the
            // thing it moves is not a handle.
            geometry.firstMaterial?.readsFromDepthBuffer = false
            let child = SCNNode(geometry: geometry)
            child.simdPosition = SIMD3<Float>(0, height, 0)
            child.renderingOrder = 10
            return child
        }

        node.addChildNode(part(SCNCylinder(radius: 0.022, height: 1), at: 0.5))
        node.addChildNode(part(SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.22), at: 1.11))

        // The touch target is far larger than the drawing: a shaft a few points
        // wide is not something a finger can find, and only this node is named, so
        // only this node answers a hit test.
        let target = SCNCylinder(radius: 0.15, height: 1.35)
        target.firstMaterial?.colorBufferWriteMask = []
        target.firstMaterial?.writesToDepthBuffer = false
        let targetNode = SCNNode(geometry: target)
        targetNode.name = name
        targetNode.simdPosition = SIMD3<Float>(0, 0.675, 0)
        node.addChildNode(targetNode)

        // Cylinders and cones are built along Y, so the across-the-bed handle is
        // the one that has to be turned.
        if alongX {
            node.simdRotation = SIMD4<Float>(0, 0, 1, -.pi / 2)
        }
        return node
    }

    private func rotationHandle() -> SCNNode {
        let ring = SCNTorus(ringRadius: 0.8, pipeRadius: 0.02)
        ring.firstMaterial?.diffuse.contents = UIColor.systemIndigo
        ring.firstMaterial?.lightingModel = .constant
        ring.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: ring)
        node.renderingOrder = 10

        let target = SCNTorus(ringRadius: 0.8, pipeRadius: 0.11)
        target.firstMaterial?.colorBufferWriteMask = []
        target.firstMaterial?.writesToDepthBuffer = false
        let targetNode = SCNNode(geometry: target)
        targetNode.name = "gizmo.ring"
        node.addChildNode(targetNode)

        // A torus is built around Y; the part turns about the bed's up axis.
        node.simdRotation = SIMD4<Float>(1, 0, 0, .pi / 2)
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
