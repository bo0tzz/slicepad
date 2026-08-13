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
    /// Whether the rings snap to 15°. Off while the part is being settled onto a
    /// face instead, where a grid of angles is only in the way.
    var snapAngles = true
    /// Where the object was dragged to, in bed millimetres, once the finger lifts.
    var onMove: ((Double, Double) -> Void)?
    /// All three angles in degrees, once a ring is released. The current values
    /// arrive with the geometry, since only Z has a control to read them from.
    var onRotate: ((Double, Double, Double) -> Void)?

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
        context.coordinator.rotation = geometry.rotation
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
                    // The part's middle, not the bed under it: rings that turn a
                    // part about its own centre are the ones that behave the way a
                    // hand expects, and two of the three are no longer horizontal.
                    let centre = (bounds.min + bounds.max) / 2
                    let built = gizmoNode(centre: centre)
                    root.addChildNode(built.node)
                    context.coordinator.gizmo = built.node
                    context.coordinator.rings = built.rings
                    context.coordinator.gizmoCentre = centre
                    context.coordinator.updateHandleScale()
                    context.coordinator.updateRingVisibility()
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
        // Framed for a new model and for a new slice, but never for a change of
        // view — switching between them keeps the camera where it was put.
        let framing = geometry.modelGeneration * 1000 + geometry.sliceGeneration
        if context.coordinator.framedGeneration != framing, let bounds = geometry.bounds {
            context.coordinator.framedGeneration = framing
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
        var onRotate: ((Double, Double, Double) -> Void)?
        var objectOffset = SIMD2<Float>(0, 0)
        var snapAngles = true
        var rotation = SIMD3<Float>(0, 0, 0)

        weak var modelNode: SCNNode?
        weak var gizmo: SCNNode?
        var rings: [String: SCNNode] = [:]
        var gizmoCentre = SIMD3<Float>(0, 0, 0)

        /// What the one-finger gesture is doing for its lifetime, decided when it
        /// starts: a handle if it began on one, the part if it began on that, and
        /// otherwise the camera — so a drag from empty plate still turns the view.
        private enum Handle: Equatable { case body, axisX, axisY, ring(Int) }
        private var handle: Handle?
        private var startPoint = SIMD3<Float>(0, 0, 0)
        private var startAngle: Float = 0

        /// The bed axes, in the order the engine takes its rotations, paired with
        /// the name of the ring that turns about each.
        static let ringNames = ["gizmo.ring.x", "gizmo.ring.y", "gizmo.ring.z"]
        static func axis(_ index: Int) -> SIMD3<Float> {
            index == 0 ? SIMD3(1, 0, 0) : (index == 1 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        }

        /// Rings too close to edge-on to aim at. A ring seen edge-on is a line, and
        /// two of them crossing at a point is not something a finger can pick
        /// between — so those stop being targets and say so by fading.
        private var edgeOn: Set<Int> = []

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
            updateRingVisibility()
        }

        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)

            if gesture.state == .began {
                handle = grabbed(at: location)
                if let handle, case let .ring(index) = handle {
                    startAngle = angle(at: location, about: index) ?? 0
                } else {
                    startPoint = planePoint(at: location, normal: Self.axis(2))
                        ?? SIMD3<Float>(repeating: 0)
                }
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

            var bestRing: (index: Int, facing: Float)?
            for hit in hits {
                guard let name = hit.node.name else { continue }
                if name == "gizmo.x" { return .axisX }
                if name == "gizmo.y" { return .axisY }
                guard let index = Self.ringNames.firstIndex(of: name), !edgeOn.contains(index) else {
                    continue
                }
                // Where rings overlap — and near their crossings they always do —
                // the one being looked at most squarely is the one being aimed at.
                let squareness = facing(index)
                if squareness > (bestRing?.facing ?? -1) {
                    bestRing = (index, squareness)
                }
            }
            if let bestRing { return .ring(bestRing.index) }

            return hits.contains(where: { $0.node.name == "model" }) ? .body : nil
        }

        /// Moves the nodes while the finger is down and tells the engine once, when
        /// it lifts. Re-transforming the mesh for every touch event would drag a
        /// whole model's triangles across the ABI several times a second.
        private func drag(_ handle: Handle, _ gesture: UIPanGestureRecognizer) {
            guard let view, let modelNode else { return }
            let location = gesture.location(in: view)
            let finished = gesture.state == .ended || gesture.state == .cancelled

            if case let .ring(index) = handle {
                let axis = Self.axis(index)
                guard let now = angle(at: location, about: index),
                      let point = planePoint(at: location, normal: axis) else { return }

                // Snapped at the ring, free beyond it. The arc a finger covers per
                // degree grows with the radius, so the gesture is coarse where it
                // starts and fine where there is room — and there is no modifier to
                // discover.
                let free = simd_length(point - gizmoCentre) > ringRadius * 2
                let held = Double(rotation[index])
                var absolute = held + Double(now - startAngle) * 180 / .pi
                if !free && snapAngles {
                    absolute = (absolute / 15).rounded() * 15
                }

                modelNode.simdTransform = Self.rotation(Float((absolute - held) * .pi / 180),
                                                        about: gizmoCentre, axis: axis)
                if finished {
                    var angles = SIMD3<Double>(Double(rotation.x), Double(rotation.y),
                                               Double(rotation.z))
                    angles[index] = Self.normalised(absolute)
                    onRotate?(angles.x, angles.y, angles.z)
                }
                return
            }

            // Translation is read on the horizontal plane through the gizmo rather
            // than on the bed, so the part keeps up with the finger even though the
            // handles now sit at its middle.
            guard let now = planePoint(at: location, normal: Self.axis(2)) else { return }
            var delta = now - startPoint
            delta.z = 0
            if handle == .axisX { delta.y = 0 }
            if handle == .axisY { delta.x = 0 }

            // Inside the root node the axes are the bed's own, which is why this is
            // (x, y, 0) rather than the scene's (x, 0, -y).
            modelNode.simdPosition = SIMD3<Float>(delta.x, delta.y, 0)
            gizmo?.simdPosition = gizmoCentre + SIMD3<Float>(delta.x, delta.y, 0)
            if finished {
                onMove?(Double(objectOffset.x + delta.x), Double(objectOffset.y + delta.y))
            }
        }

        private static func rotation(_ radians: Float, about centre: SIMD3<Float>,
                                     axis: SIMD3<Float>) -> simd_float4x4 {
            let spin = simd_float4x4(simd_quatf(angle: radians, axis: axis))
            return translation(centre) * spin * translation(-centre)
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

        /// Where a screen point lands on the plane through the gizmo with the given
        /// normal, in engine millimetres. Intersected rather than derived from the
        /// finger's movement, so a handle stays under the finger at any angle and
        /// any zoom — and a ring needs its own plane, not the bed's.
        private func planePoint(at location: CGPoint, normal engineNormal: SIMD3<Float>) -> SIMD3<Float>? {
            guard let view else { return nil }
            let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
            let origin = SIMD3<Float>(near.x, near.y, near.z)
            let direction = SIMD3<Float>(far.x, far.y, far.z) - origin

            let normal = Self.toWorld(engineNormal)
            let slope = simd_dot(direction, normal)
            // Parallel to the plane: the ray never meets it, and a ring seen exactly
            // edge-on is precisely this case.
            guard abs(slope) > 1e-6 else { return nil }

            let distance = simd_dot(Self.toWorld(gizmoCentre) - origin, normal) / slope
            guard distance > 0 else { return nil }
            return Self.toEngine(origin + direction * distance)
        }

        /// How far around the given axis a touch sits, measured in that axis's own
        /// plane so all three rings read the same way.
        private func angle(at location: CGPoint, about index: Int) -> Float? {
            let axis = Self.axis(index)
            guard let point = planePoint(at: location, normal: axis) else { return nil }
            let arm = point - gizmoCentre
            guard simd_length(arm) > 1e-4 else { return nil }

            // A right-handed pair for each axis, so a positive drag turns the part
            // the way the engine's positive angle does.
            let (u, v) = Self.basis(index)
            return atan2(simd_dot(arm, v), simd_dot(arm, u))
        }

        /// How squarely a ring faces the camera: 1 is flat on, 0 is edge-on.
        func facing(_ index: Int) -> Float {
            let toGizmo = Self.toWorld(gizmoCentre) - cameraNode.simdPosition
            guard simd_length(toGizmo) > 1e-4 else { return 1 }
            return abs(simd_dot(Self.toWorld(Self.axis(index)), simd_normalize(toGizmo)))
        }

        /// Rings that have turned nearly edge-on stop being targets and fade, since
        /// a line crossing another line is not something a finger can choose
        /// between. Two of the three are always usable, which is enough to turn the
        /// part until the third comes back.
        func updateRingVisibility() {
            edgeOn = []
            for index in 0 ..< Self.ringNames.count {
                let squareness = facing(index)
                if squareness < 0.15 {
                    edgeOn.insert(index)
                }
                rings[Self.ringNames[index]]?.opacity = squareness < 0.15 ? 0.15 : 1
            }
        }

        /// The root node turns the engine's Z-up coordinates into the scene's
        /// Y-up ones; these are that mapping and its inverse, for the ray work that
        /// has to happen in world space.
        static func toWorld(_ engine: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(engine.x, engine.z, -engine.y)
        }

        static func toEngine(_ world: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(world.x, -world.z, world.y)
        }

        private static func basis(_ index: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            switch index {
            case 0: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
            case 1: return (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
            default: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
            }
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

    /// Handles for placing the part: an arrow along each bed axis, and a ring about
    /// each for turning it. Built at unit size, because the coordinator scales the
    /// whole thing to a fixed size on screen.
    ///
    /// The rings are handed back by name as well as attached, so the coordinator can
    /// fade the ones that have turned edge-on.
    private func gizmoNode(centre: SIMD3<Float>) -> (node: SCNNode, rings: [String: SCNNode]) {
        let node = SCNNode()
        node.simdPosition = centre

        // Warm across, cool away, and a third for up: each ring shares its axis's
        // colour with the arrow along it, so the pair reads as one axis.
        let colours: [UIColor] = [.systemRed, .systemBlue, .systemIndigo]

        node.addChildNode(axisHandle(named: "gizmo.x", colour: colours[0], alongX: true))
        node.addChildNode(axisHandle(named: "gizmo.y", colour: colours[1], alongX: false))

        var rings: [String: SCNNode] = [:]
        for index in 0 ..< Coordinator.ringNames.count {
            let name = Coordinator.ringNames[index]
            let ring = rotationHandle(named: name, colour: colours[index], axis: index)
            node.addChildNode(ring.node)
            rings[name] = ring.visible
        }
        return (node, rings)
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

    /// One ring, lying in the plane the given axis is normal to. The visible torus
    /// is returned separately because fading it is how an edge-on ring says it is
    /// not a target.
    private func rotationHandle(named name: String, colour: UIColor,
                                axis index: Int) -> (node: SCNNode, visible: SCNNode) {
        let ring = SCNTorus(ringRadius: 0.8, pipeRadius: 0.02)
        ring.firstMaterial?.diffuse.contents = colour
        ring.firstMaterial?.lightingModel = .constant
        ring.firstMaterial?.readsFromDepthBuffer = false
        let visible = SCNNode(geometry: ring)
        visible.name = name
        visible.renderingOrder = 10

        let target = SCNTorus(ringRadius: 0.8, pipeRadius: 0.11)
        target.firstMaterial?.colorBufferWriteMask = []
        target.firstMaterial?.writesToDepthBuffer = false
        let targetNode = SCNNode(geometry: target)
        targetNode.name = name
        visible.addChildNode(targetNode)

        // A torus is built around Y, which is already the bed's second axis; the
        // other two are that ring turned onto their own.
        let node = SCNNode()
        node.addChildNode(visible)
        if index == 0 {
            node.simdRotation = SIMD4<Float>(0, 0, 1, -.pi / 2)
        } else if index == 2 {
            node.simdRotation = SIMD4<Float>(1, 0, 0, .pi / 2)
        }
        return (node, visible)
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
