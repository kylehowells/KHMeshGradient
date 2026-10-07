import KHMeshGradient
import SwiftUI
import UIKit

final class GalleryViewController: UIViewController {
	private var cards: [MeshCardViewController] = []
	override func loadView() { self.view = GalleryView() }
	var _view: GalleryView { self.view as! GalleryView }

	override func viewDidLoad() {
		super.viewDidLoad()
		for sample in MeshSample.all {
			let card: MeshCardViewController = MeshCardViewController(sample: sample)
			self.addChild(card)
			self._view.scrollView.addSubview(card.view)
			card.didMove(toParent: self)
			self.cards.append(card)
		}
		self._view.cards = self.cards.map({ $0._view })
		self._view.animateButton.addTarget(self, action: #selector(self.animateMesh), for: .touchUpInside)
		self._view.resetButton.addTarget(self, action: #selector(self.resetMeshes), for: .touchUpInside)
		self._view.scrubSlider.addTarget(self, action: #selector(self.scrubChanged), for: .valueChanged)
		self._view.resumeButton.addTarget(self, action: #selector(self.resumeMeshes), for: .touchUpInside)
		self._view.debugControl.addTarget(self, action: #selector(self.debugChanged), for: .valueChanged)
		self._view.geometryControl.addTarget(self, action: #selector(self.geometryChanged), for: .valueChanged)
	}

	@objc private func animateMesh() { for card in self.cards { card.animateMesh() } }
	@objc private func scrubChanged() { for card in self.cards { card.scrub(to: CGFloat(self._view.scrubSlider.value)) } }
	@objc private func resumeMeshes() { for card in self.cards { card.resume() } }
	@objc private func resetMeshes() { for card in self.cards { card.reset() } }
	@objc private func debugChanged() {
		let modes: [KHMeshGradientView.DebugMode] = [.none, .mesh, .controlPoints, .tessellation]
		for card in self.cards { card._view.gradient.debugMode = modes[self._view.debugControl.selectedSegmentIndex] }
	}
	@objc private func geometryChanged() {
		for card in self.cards { card._view.gradient.subdivisions = self._view.geometryControl.selectedSegmentIndex == 0 ? 0 : 48 }
	}
}

final class GalleryView: UIView {
	let heading: UILabel = {
		let label: UILabel = UILabel()
		label.text = "Mesh Gradients"
		label.font = .systemFont(ofSize: 30, weight: .bold)
		return label
	}()
	let subtitle: UILabel = {
		let label: UILabel = UILabel()
		label.text = "UIKit + Metal and SwiftUI · identical inputs"
		label.font = .systemFont(ofSize: 14)
		label.textColor = .secondaryLabel
		return label
	}()
	let animateButton: UIButton = {
		let button: UIButton = UIButton(type: .system)
		button.setTitle("Animate", for: .normal)
		button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
		button.accessibilityIdentifier = "animateMesh"
		return button
	}()
	let resetButton: UIButton = {
		let button: UIButton = UIButton(type: .system)
		button.setTitle("Reset", for: .normal)
		return button
	}()
	let scrubLabel: UILabel = {
		let label = UILabel()
		label.text = "Scrub UIKit"
		label.font = .systemFont(ofSize: 13)
		return label
	}()
	let scrubSlider: UISlider = UISlider()
	let resumeButton: UIButton = {
		let button = UIButton(type: .system)
		button.setTitle("Resume", for: .normal)
		return button
	}()
	let debugControl: UISegmentedControl = UISegmentedControl(items: ["Gradient", "Mesh", "Handles", "Grid"])
	let geometryControl: UISegmentedControl = UISegmentedControl(items: ["Adaptive geometry", "Fixed 48"])
	let scrollView: UIScrollView = UIScrollView()
	var cards: [MeshCardView] = [] { didSet { self.setNeedsLayout() } }

	override init(frame: CGRect) {
		super.init(frame: frame)
		self.backgroundColor = .systemGroupedBackground
		for view in [self.heading, self.subtitle, self.animateButton, self.resetButton, self.debugControl, self.geometryControl, self.scrubLabel, self.scrubSlider, self.resumeButton, self.scrollView] { self.addSubview(view) }
		self.debugControl.selectedSegmentIndex = 0
		self.geometryControl.selectedSegmentIndex = 0
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let width: CGFloat = self.bounds.width
		let top: CGFloat = self.safeAreaInsets.top + 16
		self.heading.frame = CGRect(x: 20, y: top, width: width - 40, height: 38)
		self.subtitle.frame = CGRect(x: 20, y: top + 42, width: width - 40, height: 22)
		self.animateButton.frame = CGRect(x: 20, y: top + 72, width: 92, height: 36)
		self.resetButton.frame = CGRect(x: 118, y: top + 72, width: 64, height: 36)
		self.debugControl.frame = CGRect(x: 20, y: top + 118, width: width - 40, height: 32)
		self.geometryControl.frame = CGRect(x: 20, y: top + 162, width: width - 40, height: 32)
		self.scrubLabel.frame = CGRect(x: 20, y: top + 202, width: 80, height: 32)
		self.scrubSlider.frame = CGRect(x: 105, y: top + 202, width: max(40, width - 205), height: 32)
		self.resumeButton.frame = CGRect(x: width - 92, y: top + 202, width: 72, height: 32)
		let scrollTop: CGFloat = top + 248
		self.scrollView.frame = CGRect(x: 0, y: scrollTop, width: width, height: self.bounds.height - scrollTop)
		var y: CGFloat = 0
		let cardHeight: CGFloat = min(330, (width - 52) * 0.34 + 110)
		for card in self.cards {
			card.frame = CGRect(x: 20, y: y, width: width - 40, height: cardHeight)
			y += cardHeight + 16
		}
		self.scrollView.contentSize = CGSize(width: width, height: y + self.safeAreaInsets.bottom)
	}
}

final class MeshCardViewController: UIViewController {
	private let original: MeshSample
	private let state: MeshSampleState
	private var alternate: Bool = false
	private var hosting: UIViewController?
	private var propertyAnimator: UIViewPropertyAnimator?
	init(sample: MeshSample) { self.original = sample; self.state = MeshSampleState(sample: sample); super.init(nibName: nil, bundle: nil) }
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
	override func loadView() { self.view = MeshCardView() }
	var _view: MeshCardView { self.view as! MeshCardView }

	override func viewDidLoad() {
		super.viewDidLoad()
		self._view.titleLabel.text = self.original.title
		self._view.detailLabel.text = self.original.detail
		self.original.apply(to: self._view.gradient)
		if #available(iOS 18.0, *) {
			let controller = UIHostingController(rootView: ObservedSwiftUIMesh(state: self.state))
			controller.view.backgroundColor = .clear
			self.addChild(controller)
			self._view.referenceContainer.addSubview(controller.view)
			controller.didMove(toParent: self)
			self.hosting = controller
			self._view.referenceView = controller.view
		}
		else {
			let label: UILabel = UILabel()
			label.text = "SwiftUI MeshGradient\nrequires iOS 18"
			label.numberOfLines = 2
			label.textAlignment = .center
			label.font = .systemFont(ofSize: 12)
			self._view.referenceContainer.addSubview(label)
			self._view.referenceView = label
		}
	}

	func animateMesh() {
		if self.propertyAnimator?.state == .active { self.propertyAnimator?.stopAnimation(true) }
		self.propertyAnimator = nil
		self.alternate.toggle()
		var target: MeshSample = self.original
		if target.size.width > 2 {
			let index: Int = target.size.width + 1
			target.points[index] = self.alternate ? CGPoint(x: 0.3, y: 0.68) : self.original.points[index]
		}
		else {
			target.colors[0] = self.alternate ? .systemPink : self.original.colors[0]
		}
		UIView.animate(withDuration: 2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
			target.apply(to: self._view.gradient)
		}, completion: nil)
		withAnimation(.easeInOut(duration: 2), {
			self.state.sample = target
		})
	}

	func scrub(to fraction: CGFloat) {
		if self.propertyAnimator?.state != .active {
			self.reset()
			var target = self.original
			if target.size.width > 2 { target.points[target.size.width + 1] = CGPoint(x: 0.3, y: 0.68) }
			else { target.colors[0] = .systemPink }
			let animator = UIViewPropertyAnimator(duration: 2, curve: .easeInOut, animations: { [weak self] in
				guard let self = self else { return }
				target.apply(to: self._view.gradient)
			})
			self.propertyAnimator = animator
			animator.startAnimation()
		}
		self.propertyAnimator?.pauseAnimation()
		self.propertyAnimator?.fractionComplete = fraction
	}

	func resume() {
		guard let animator = self.propertyAnimator, animator.state == .active, !animator.isRunning else { return }
		animator.continueAnimation(withTimingParameters: nil, durationFactor: 1)
	}

	func reset() {
		if self.propertyAnimator?.state == .active { self.propertyAnimator?.stopAnimation(true) }
		self.propertyAnimator = nil
		self.alternate = false
		self._view.gradient.layer.removeAllAnimations()
		UIView.performWithoutAnimation({ self.original.apply(to: self._view.gradient) })
		self.state.sample = self.original
	}
}

final class MeshCardView: UIView {
	let gradient: KHMeshGradientView = KHMeshGradientView()
	let referenceContainer: UIView = UIView()
	var referenceView: UIView?
	let titleLabel: UILabel = UILabel()
	let detailLabel: UILabel = UILabel()
	private let oursLabel: UILabel = UILabel()
	private let referenceLabel: UILabel = UILabel()

	override init(frame: CGRect) {
		super.init(frame: frame)
		self.backgroundColor = .secondarySystemGroupedBackground
		self.layer.cornerRadius = 16
		self.titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
		self.detailLabel.font = .systemFont(ofSize: 12)
		self.detailLabel.textColor = .secondaryLabel
		self.oursLabel.text = "KHMeshGradientView"
		self.referenceLabel.text = "SwiftUI MeshGradient"
		for label in [self.oursLabel, self.referenceLabel] { label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .secondaryLabel }
		for view in [self.titleLabel, self.detailLabel, self.oursLabel, self.referenceLabel, self.gradient, self.referenceContainer] { self.addSubview(view) }
		for view in [self.gradient, self.referenceContainer] {
			view.backgroundColor = .white
			view.layer.cornerRadius = 8
			view.clipsToBounds = true
		}
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let width: CGFloat = self.bounds.width
		let column: CGFloat = (width - 36) / 2
		self.titleLabel.frame = CGRect(x: 12, y: 12, width: width - 24, height: 22)
		self.detailLabel.frame = CGRect(x: 12, y: 36, width: width - 24, height: 18)
		self.oursLabel.frame = CGRect(x: 12, y: 62, width: column, height: 18)
		self.referenceLabel.frame = CGRect(x: 24 + column, y: 62, width: column, height: 18)
		self.gradient.frame = CGRect(x: 12, y: 86, width: column, height: self.bounds.height - 98)
		self.referenceContainer.frame = CGRect(x: 24 + column, y: 86, width: column, height: self.bounds.height - 98)
		self.referenceView?.frame = self.referenceContainer.bounds
	}
}

#if DEBUG
private struct GalleryPreview: UIViewControllerRepresentable {
	func makeUIViewController(context: Context) -> GalleryViewController { GalleryViewController() }
	func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {
		uiViewController.view.setNeedsLayout(); uiViewController.view.layoutIfNeeded()
	}
}
private struct GalleryPreviewProvider: PreviewProvider {
	static var previews: some View { GalleryPreview().ignoresSafeArea().previewDisplayName("Mesh comparison gallery") }
}
#endif
