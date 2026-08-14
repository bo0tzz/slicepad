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
        // Lit explicitly rather than with autoenablesDefaultLighting, which gives
        // one light and no ambient: a toolpath is thousands of small surfaces
        // facing every direction, and the ones facing away from a single light
        // render pure black. The solid model got away with it because its faces are
        // few and large.
        //
        // Kept dim, though. Ambient reaches into the gap between two beads exactly
        // as strongly as it reaches the outside of the part, so a bright one erases
        // every crevice a sliced print is made of and leaves a flat mass of colour.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 220
        view.scene?.rootNode.addChildNode(ambient)

        // Both directional lights are carried by the camera, so turning the plate
        // does not swing a part into shadow — but aimed off the view axis rather
        // than straight down the lens, which lights everything facing you equally
        // and so shades a round bead like a flat ribbon.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 950
        key.eulerAngles = SCNVector3(-0.5, 0.55, 0)

        // Opposite and much dimmer, so the faces the key light misses are still
        // shaped by a direction instead of being left to ambient.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 320
        fill.eulerAngles = SCNVector3(0.35, -0.9, 0)

        // And one from overhead, fixed to the scene rather than carried by the
        // camera. Both of the others are aimed across the view, so nothing lit an
        // upward-facing surface — which in a layer view is the top of every layer
        // and every bead, most of what there is to look at. They were left to
        // ambient alone, and a flat one like the prime line came out nearly black.
        // Down and slightly to one side, the way you would look at a print on a
        // bench under a ceiling light.
        let overhead = SCNNode()
        overhead.light = SCNLight()
        overhead.light?.type = .directional
        overhead.light?.intensity = 500
        overhead.eulerAngles = SCNVector3(-1.15, 0.4, 0)
        view.scene?.rootNode.addChildNode(overhead)

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
        // An extrusion is a fraction of a millimetre across, so at any zoom that
        // shows a whole layer the beads are a pixel or two wide and stair-step
        // into each other without this.
        view.antialiasingMode = .multisampling4X
        context.coordinator.cameraNode.addChildNode(key)
        context.coordinator.cameraNode.addChildNode(fill)
        // Lighting alone cannot say which of two beads is the one further in: both
        // face the same way and take the same light. Occlusion is the part of the
        // picture that reads as depth, and the radius is in bed millimetres — a
        // couple of extrusion widths, so it darkens the seams between beads rather
        // than shading a whole region flat.
        if let camera = context.coordinator.cameraNode.camera {
            camera.screenSpaceAmbientOcclusionIntensity = 1.6
            camera.screenSpaceAmbientOcclusionRadius = 1.5
            camera.screenSpaceAmbientOcclusionBias = 0.02
        }
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

        // Picking the part up and putting it down. A tap and a drag do not compete —
        // a tap that moves becomes the drag — so this needs no relationship with the
        // others.
        let select = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.select(_:)))
        view.addGestureRecognizer(select)

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onRotate = onRotate
        context.coordinator.objectOffset = geometry.offset
        context.coordinator.rotation = geometry.rotation
        context.coordinator.snapAngles = snapAngles
        guard let root = view.scene?.rootNode.childNode(withName: "root", recursively: false) else { return }

        // SwiftUI re-runs this for any state change at all, progress ticks included.
        let state = Coordinator.State(revision: geometry.revision, display: display,
                                      layers: visibleLayers)
        guard context.coordinator.state != state else { return }
        context.coordinator.state = state

        // A newly opened part is not the part that was selected, and arriving with
        // handles already on it would undo the point of having to pick it up.
        if context.coordinator.selectedGeneration != geometry.modelGeneration {
            context.coordinator.selectedGeneration = geometry.modelGeneration
            context.coordinator.isSelected = false
        }

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
                    context.coordinator.arrows = built.arrows
                    context.coordinator.gizmoCentre = centre
                    // Built every time the geometry changes, so the selection has to
                    // be re-applied to the new nodes rather than assumed of them.
                    built.node.isHidden = !context.coordinator.isSelected
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
        // Framed for a new model and for a new slice, but never for a change of
        // view — switching between them keeps the camera where it was put.
        let framing = geometry.modelGeneration * 1000 + geometry.sliceGeneration
        if context.coordinator.framedGeneration != framing, let bounds = geometry.bounds {
            context.coordinator.framedGeneration = framing
            // On the part for a finished slice, on the bed for a new model: one
            // asks what the print looks like, the other where it sits. At bed zoom
            // an extrusion is about a pixel and a layer is less, so a print framed
            // that way is a smudge.
            let framingBed = geometry.sliceGeneration > 0 && display == .layers ? [] : geometry.bed
            frameCamera(context.coordinator, bed: framingBed, bounds: bounds)
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
        var arrows: [String: SCNNode] = [:]
        var gizmoCentre = SIMD3<Float>(0, 0, 0)

        /// Whether the part is picked up. Handles on screen at all times are five
        /// things to look past to see the part, and they claim the middle of the view
        /// where a finger lands to turn the camera; nothing is shown until a tap says
        /// the part is what the next drag is about.
        var isSelected = false
        /// Which model the selection belongs to, so opening another part drops it.
        var selectedGeneration: Int?

        /// What the one-finger gesture is doing for its lifetime, decided when it
        /// starts: a handle if it began on one, the part if it began on that, and
        /// otherwise the camera — so a drag from empty plate still turns the view.
        private enum Handle: Equatable { case body, axisX, axisY, ring(Int) }
        private var handle: Handle?
        private var startPoint = SIMD3<Float>(0, 0, 0)
        private var startAngle: Float = 0

        /// How far the current ring drag has turned, in degrees, carried across the
        /// seam in the angle it is measured from: atan2 comes back on -180...180, so
        /// without this a finger crossing that line reads as a turn the long way round
        /// and the part spins backwards through most of a circle.
        private var turnedBy: Double = 0

        /// The bed axes, in the order the engine takes its rotations, paired with
        /// the name of the ring that turns about each.
        static let ringNames = ["gizmo.ring.x", "gizmo.ring.y", "gizmo.ring.z"]
        static let axisNames = ["X", "Y", "Z"]
        static let arrowNames = ["gizmo.x", "gizmo.y"]
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

        /// The three rings are nested rather than concentric at one radius. Same-size
        /// rings about the three axes genuinely meet — six points, on the axes — and
        /// each crossing is somewhere a finger cannot say which ring it means. Nested,
        /// they only ever overlap in projection, and they are spaced wider apart than
        /// their touch bands are thick, so a touch usually answers for one ring alone.
        static let unitRingRadii: [Float] = [0.7, 0.95, 1.2]
        func ringRadius(_ index: Int) -> Float { Self.unitRingRadii[index] * handleScale }

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
            // Free from directly overhead to directly underneath, stopping just
            // short of either pole: at one the horizontal offset vanishes, yaw
            // stops meaning anything, and dragging through it flips the view over.
            let overhead = Float.pi / 2 - 0.02
            pitch = min(max(pitch, -overhead), overhead)
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
            updateHandleScale()
        }

        /// Kept a constant size on screen, so the handles neither shrink out of
        /// reach when the whole bed is in view nor swamp the part up close.
        func updateHandleScale() {
            guard let view, view.bounds.height > 0 else { return }
            let fieldOfView = Float(cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
            let perPoint = 2 * distance * tan(fieldOfView / 2) / Float(view.bounds.height)
            // 70 rather than the 90 this started at: the arrows now stand outside the
            // outermost ring instead of running out from the middle, and at the old
            // scale that put their tips a third of a screen from the part.
            handleScale = perPoint * 70
            gizmo?.simdScale = SIMD3<Float>(repeating: handleScale)
            updateHandleVisibility()
        }

        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)

            if gesture.state == .began {
                handle = grabbed(at: location)
                if let handle, case let .ring(index) = handle {
                    // A ring whose angle will not read is one seen exactly edge-on.
                    // Starting from zero there would throw the part to an angle that
                    // has nothing to do with the touch, so the camera takes the drag.
                    if let start = angle(at: location, about: index) {
                        startAngle = start
                        turnedBy = 0
                    } else {
                        self.handle = nil
                    }
                } else {
                    startPoint = planePoint(at: location, normal: Self.axis(2))
                        ?? SIMD3<Float>(repeating: 0)
                }
                updateHandleVisibility()
            }

            if let handle {
                drag(handle, gesture)
                if gesture.state == .ended || gesture.state == .cancelled {
                    self.handle = nil
                    updateHandleVisibility()
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

        /// Picks the part up, or puts it down. A drag decides nothing about selection:
        /// while nothing is picked up every drag turns the camera, including one that
        /// starts on the part — on a plate where the part fills the middle of the view
        /// the alternative is a camera that can only be turned from the corners, and a
        /// part that moves whenever a finger tries.
        @objc func select(_ gesture: UITapGestureRecognizer) {
            guard let view, gesture.state == .ended else { return }
            let hits = view.hitTest(gesture.location(in: view),
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            let names = hits.compactMap { $0.node.name }

            // A tap that lands on a handle was aimed at the gizmo, and must not put
            // away the thing it was aimed at.
            guard !names.contains(where: { $0.hasPrefix("gizmo") }) else { return }
            setSelected(names.contains("model"))
        }

        func setSelected(_ selected: Bool) {
            guard isSelected != selected else { return }
            isSelected = selected
            gizmo?.isHidden = !selected
        }

        private func grabbed(at location: CGPoint) -> Handle? {
            // Nothing picked up means nothing to grab: the whole screen is the camera.
            guard isSelected, let view else { return nil }
            // Every result rather than the nearest: the handles are drawn over the
            // part, so a touch near one lands on both and the handle has to win.
            let hits = view.hitTest(location,
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue])

            var bestRing: (index: Int, facing: Float)?
            for hit in hits {
                guard let name = hit.node.name else { continue }
                if name == Self.arrowNames[0] { return .axisX }
                if name == Self.arrowNames[1] { return .axisY }
                guard let index = Self.ringNames.firstIndex(of: name), !edgeOn.contains(index) else {
                    continue
                }
                // Nested radii keep the rings from meeting, but a turned view still
                // draws one across another: where two answer the same touch, the one
                // being looked at most squarely is the one being aimed at.
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

                // Carried across the seam, so a finger that keeps going keeps turning
                // the part the same way however far round it travels.
                var raw = Double(now - startAngle) * 180 / .pi
                while raw - turnedBy > 180 { raw -= 360 }
                while raw - turnedBy < -180 { raw += 360 }
                turnedBy = raw

                // Snapped at the ring, free beyond it. The arc a finger covers per
                // degree grows with the radius, so the gesture is coarse where it
                // starts and fine where there is room — and there is no modifier to
                // discover.
                let free = simd_length(point - gizmoCentre) > ringRadius(index) * 2
                // The turn is snapped, not the angle it lands on. Snapping the angle
                // moved the part the instant it was touched: the engine's angles are
                // whatever auto-orient or a face settle left behind, never multiples of
                // 15, so the first thing a ring did was jump by up to half a step and
                // only then start following the finger.
                var turn = raw
                if !free && snapAngles {
                    turn = (turn / 15).rounded() * 15
                }

                modelNode.simdTransform = Self.rotation(Float(turn * .pi / 180),
                                                        about: gizmoCentre, axis: axis)
                // Desktop shows the angle while a ring turns, and a ring without it is
                // a guess: snapped or not, nothing else on screen says how far round
                // the part has come, or which axis it went round.
                let shown = turn.rounded() == 0 ? 0 : turn   // never -0°
                show(Self.axisNames[index] + String(format: " %+.0f°", shown))
                if finished {
                    let angles = self.angles(turning: Float(turn * .pi / 180), about: axis)
                    onRotate?(angles.x, angles.y, angles.z)
                    show(nil)
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
            show(String(format: "%.1f, %.1f mm",
                        Double(objectOffset.x + delta.x), Double(objectOffset.y + delta.y)))
            if finished {
                onMove?(Double(objectOffset.x + delta.x), Double(objectOffset.y + delta.y))
                show(nil)
            }
        }

        /// The number the gesture is producing, over the top of the plate. A UILabel
        /// rather than anything in the scene: it has to stay the same size and stay
        /// upright whatever the camera is doing, which is what the overlay is for.
        private lazy var readout: UILabel = {
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textAlignment = .center
            label.textColor = .label
            label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            label.isHidden = true
            return label
        }()

        private func show(_ text: String?) {
            guard let view else { return }
            if readout.superview !== view { view.addSubview(readout) }
            guard let text else {
                readout.isHidden = true
                return
            }
            readout.text = " \(text) "
            readout.sizeToFit()
            var size = readout.bounds.size
            size.width += 16
            size.height += 8
            readout.bounds.size = size
            readout.center = CGPoint(x: view.bounds.midX,
                                     y: view.safeAreaInsets.top + size.height / 2 + 12)
            readout.isHidden = false
        }

        /// The three angles the engine should hold once the part has been turned
        /// `radians` about a bed axis from where it is now.
        ///
        /// Not the axis's own angle plus the turn, which is what this used to send.
        /// The engine composes its triplet as Rz·Ry·Rx, so raising the X figure turns
        /// the part underneath the Y and Z it already has, while the ring turned it
        /// about the bed's X — on the outside of both. With the part auto-oriented,
        /// which is its usual state, those are different orientations, and the part
        /// jumped from the one the drag showed to the other the moment the finger came
        /// off. Composing the turn where the gesture put it and re-deriving all three
        /// angles is what makes releasing a ring keep what turning it showed.
        private func angles(turning radians: Float, about axis: SIMD3<Float>) -> SIMD3<Double> {
            let held = rotation * (Float.pi / 180)
            let current = Self.spin(held.z, SIMD3(0, 0, 1))
                * Self.spin(held.y, SIMD3(0, 1, 0))
                * Self.spin(held.x, SIMD3(1, 0, 0))
            return Self.anglesOf(Self.spin(radians, axis) * current)
        }

        private static func spin(_ radians: Float, _ axis: SIMD3<Float>) -> simd_float3x3 {
            simd_float3x3(simd_quatf(angle: radians, axis: axis))
        }

        /// Back the other way: the triplet that rebuilds this rotation as Rz·Ry·Rx, in
        /// degrees. Written out rather than taken from a library because it has to
        /// agree with the engine's order exactly, and the usual Euler conventions are
        /// each some other order.
        private static func anglesOf(_ m: simd_float3x3) -> SIMD3<Double> {
            // Columns, so m[column][row]: this is the matrix's row 2, column 0.
            let sinY = min(max(-m[0][2], -1), 1)
            let y = asin(sinY)
            var x: Float = 0
            var z: Float = 0
            if sqrt(max(1 - sinY * sinY, 0)) > 1e-5 {
                x = atan2(m[1][2], m[2][2])
                z = atan2(m[0][1], m[0][0])
            } else {
                // Turned to look straight along Y, where X and Z do the same thing:
                // all of it is given to Z and X keeps still.
                z = atan2(-m[1][0], m[1][1])
            }
            let degrees = SIMD3<Float>(x, y, z) * (180 / Float.pi)
            return SIMD3<Double>(normalised(Double(degrees.x)), normalised(Double(degrees.y)),
                                 normalised(Double(degrees.z)))
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

        /// What is worth aiming at, and what is being aimed at. Rings that have turned
        /// nearly edge-on stop being targets and fade: a line crossing another line is
        /// not something a finger can choose between, and a ring read at that angle
        /// turns wildly for a small movement because its plane is nearly along the view
        /// ray. One of the three is always well clear of that, which is enough to keep
        /// turning the part until the others come back.
        ///
        /// While a handle is being dragged the rest fade too, so the gizmo says which
        /// one it is following.
        func updateHandleVisibility() {
            // Was 0.15, which still allowed a ring 81° from face-on to be grabbed:
            // aimable in principle, and in practice a ring whose far side turns tens
            // of degrees for a pixel of finger, because the touch is being read
            // against a plane it is nearly travelling along.
            edgeOn = []
            for index in 0 ..< Self.ringNames.count where facing(index) < 0.2 {
                edgeOn.insert(index)
            }

            var engagedRing: Int?
            var engagedArrow: String?
            if let handle {
                switch handle {
                case .ring(let index): engagedRing = index
                case .axisX: engagedArrow = Self.arrowNames[0]
                case .axisY: engagedArrow = Self.arrowNames[1]
                case .body: break
                }
            }
            let aiming = engagedRing != nil || engagedArrow != nil

            for index in 0 ..< Self.ringNames.count {
                let quiet = edgeOn.contains(index) || (aiming && engagedRing != index)
                rings[Self.ringNames[index]]?.opacity = quiet ? 0.15 : 1
            }
            for name in Self.arrowNames {
                arrows[name]?.opacity = (aiming && engagedArrow != name) ? 0.15 : 1
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
            // Only from above. Now that the camera can go under the plate, a
            // double-sided bed is an opaque sheet across the whole view from down
            // there; culled, the outline still says where the bed is while the
            // first layer stays visible through it.
            surface.firstMaterial?.isDoubleSided = false
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

    /// Handles for placing the part, shown while it is selected: an arrow along each
    /// bed axis, and a nested ring about each for turning it. Built at unit size,
    /// because the coordinator scales the whole thing to a fixed size on screen.
    ///
    /// The handles are handed back by name as well as attached, so the coordinator can
    /// fade the rings that have turned edge-on and everything that is not the one being
    /// dragged.
    private func gizmoNode(centre: SIMD3<Float>)
        -> (node: SCNNode, rings: [String: SCNNode], arrows: [String: SCNNode]) {
        let node = SCNNode()
        node.simdPosition = centre

        // Warm across, cool away, and a third for up: each ring shares its axis's
        // colour with the arrow along it, so the pair reads as one axis.
        let colours: [UIColor] = [.systemRed, .systemBlue, .systemIndigo]

        var arrows: [String: SCNNode] = [:]
        for index in 0 ... 1 {
            let name = Coordinator.arrowNames[index]
            let arrow = axisHandle(named: name, colour: colours[index], alongX: index == 0)
            node.addChildNode(arrow)
            arrows[name] = arrow
        }

        var rings: [String: SCNNode] = [:]
        for index in 0 ..< Coordinator.ringNames.count {
            let name = Coordinator.ringNames[index]
            let ring = rotationHandle(named: name, colour: colours[index], axis: index)
            node.addChildNode(ring.node)
            rings[name] = ring.visible
        }
        return (node, rings, arrows)
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

        // Standing outside the outermost ring rather than running out from the
        // middle. An arrow from the centre crosses all three rings on its way out and
        // ends up sharing its whole length with them: the crowd the handles made was
        // mostly this, and pushing them past the rings costs nothing but reach.
        let stem: Float = 1.35
        node.addChildNode(part(SCNCylinder(radius: 0.022, height: 0.45), at: stem + 0.225))
        node.addChildNode(part(SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.22),
                               at: stem + 0.56))

        // The touch target is far larger than the drawing: a shaft a few points
        // wide is not something a finger can find, and only this node is named, so
        // only this node answers a hit test.
        let target = SCNCylinder(radius: 0.15, height: 0.72)
        target.firstMaterial?.colorBufferWriteMask = []
        target.firstMaterial?.writesToDepthBuffer = false
        let targetNode = SCNNode(geometry: target)
        targetNode.name = name
        targetNode.simdPosition = SIMD3<Float>(0, stem + 0.36, 0)
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
        let radius = CGFloat(Coordinator.unitRingRadii[index])
        let ring = SCNTorus(ringRadius: radius, pipeRadius: 0.02)
        ring.firstMaterial?.diffuse.contents = colour
        ring.firstMaterial?.lightingModel = .constant
        ring.firstMaterial?.readsFromDepthBuffer = false
        let visible = SCNNode(geometry: ring)
        visible.name = name
        visible.renderingOrder = 10

        let target = SCNTorus(ringRadius: radius, pipeRadius: 0.11)
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
        // An empty bed means frame the part instead. Framing the part is wrong for
        // a model — a 27mm object alone in the view with one corner of a 350mm bed
        // drifting past the top edge answers nothing about where it sits — and
        // right for a print, where the whole bed leaves the layers a smudge.
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
