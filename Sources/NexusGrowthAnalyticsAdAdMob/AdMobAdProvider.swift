import Foundation
import GoogleMobileAds
import NexusGrowthAnalyticsAd
import UIKit

public final class AdMobAdProvider: NSObject, AdProvider, @unchecked Sendable {
    private let rootViewControllerProvider: @Sendable () -> UIViewController?
    private let revenueReporter: @Sendable (AdRevenuePayload) -> Void
    private var appOpenAds: [AdCacheKey: AppOpenAd] = [:]
    private var interstitialAds: [AdCacheKey: InterstitialAd] = [:]
    private var rewardedAds: [AdCacheKey: RewardedAd] = [:]
    private var rewardedInterstitialAds: [AdCacheKey: RewardedInterstitialAd] = [:]
    private var fullScreenStates: [AdCacheKey: AdLoadState] = [:]
    private var pendingLoadCallbacks: [AdCacheKey: [PendingLoadCallback]] = [:]
    private var presentedAds: [ObjectIdentifier: PresentedAd] = [:]
    private var presentingKeys = Set<AdCacheKey>()
    private var appOpenPlacement: AdPlacement?
    private var shouldShowAppOpenOnForeground = false
    private var isShowingAppOpen = false
    private var callbacksByKey: [AdCacheKey: AdCallbacks] = [:]
    private var bannerDelegates: [String: BannerDelegateBox] = [:]
    private var nativeDelegates: [String: NativeDelegateBox] = [:]

    public init(
        rootViewControllerProvider: @escaping @Sendable () -> UIViewController? = { nil },
        revenueReporter: @escaping @Sendable (AdRevenuePayload) -> Void = { _ in }
    ) {
        self.rootViewControllerProvider = rootViewControllerProvider
        self.revenueReporter = revenueReporter
        super.init()
        MobileAds.shared.start(completionHandler: nil)
    }

    public func loadAd(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        runOnMain { [weak self] in
            self?.loadAdOnMain(placement, callbacks: callbacks)
        }
    }

    private func loadAdOnMain(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        guard placement.format != .banner, placement.format != .native else {
            callbacks?.onFailed(
                placement,
                error: GrowthAnalyticsError.providerUnsupported("Use loadBanner/loadNative for \(placement.format.rawValue)")
            )
            return
        }
        let key = placement.cacheKey
        switch fullScreenStates[key] ?? .idle {
        case .loaded:
            callbacks?.onLoaded(placement)
            return
        case .loading, .showing:
            enqueueLoadCallback(key: key, placement: placement, callbacks: callbacks)
            return
        case .idle:
            enqueueLoadCallback(key: key, placement: placement, callbacks: callbacks)
        }
        fullScreenStates[key] = .loading
        switch placement.format {
        case .appOpen:
            loadAppOpen(placement)
        case .interstitial:
            loadInterstitial(placement)
        case .rewarded:
            loadRewarded(placement)
        case .rewardedInterstitial:
            loadRewardedInterstitial(placement)
        case .banner, .native:
            break
        }
    }

    public func showAd(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        runOnMain { [weak self] in
            self?.showAdOnMain(placement, callbacks: callbacks)
        }
    }

    private func showAdOnMain(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        loadAdOnMain(placement, callbacks: nil)
        let root = rootViewControllerProvider()
        let key = placement.cacheKey
        guard !presentingKeys.contains(key) else {
            callbacks?.onFailed(
                placement,
                error: GrowthAnalyticsError.providerUnsupported("Ad is already showing")
            )
            return
        }
        switch placement.format {
        case .appOpen:
            guard let ad = appOpenAds.removeValue(forKey: key) else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("App open ad is not loaded"))
                return
            }
            prepareForPresentation(ad, key: key, placement: placement, callbacks: callbacks)
            attachPaidEventHandler(to: ad, placement: placement)
            ad.fullScreenContentDelegate = self
            ad.present(from: root)
        case .interstitial:
            guard let ad = interstitialAds.removeValue(forKey: key) else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Interstitial ad is not loaded"))
                return
            }
            prepareForPresentation(ad, key: key, placement: placement, callbacks: callbacks)
            attachPaidEventHandler(to: ad, placement: placement)
            ad.fullScreenContentDelegate = self
            ad.present(from: root)
        case .rewarded, .rewardedInterstitial:
            if placement.format == .rewardedInterstitial {
                guard let ad = rewardedInterstitialAds.removeValue(forKey: key) else {
                    callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded interstitial ad is not loaded"))
                    return
                }
                prepareForPresentation(ad, key: key, placement: placement, callbacks: callbacks)
                attachPaidEventHandler(to: ad, placement: placement)
                ad.fullScreenContentDelegate = self
                ad.present(from: root) { [weak callbacks] in
                    callbacks?.onReward(placement)
                }
                return
            }
            guard let ad = rewardedAds.removeValue(forKey: key) else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded ad is not loaded"))
                return
            }
            prepareForPresentation(ad, key: key, placement: placement, callbacks: callbacks)
            attachPaidEventHandler(to: ad, placement: placement)
            ad.fullScreenContentDelegate = self
            ad.present(from: root) { [weak callbacks] in
                callbacks?.onReward(placement)
            }
        case .banner, .native:
            callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Use loadBanner/loadNative for \(placement.format.rawValue)"))
        }
    }

    public func enableAppOpenLifecycle(
        placement: AdPlacement,
        showOnForeground: Bool = true,
        callbacks: AdCallbacks? = nil
    ) {
        appOpenPlacement = placement
        shouldShowAppOpenOnForeground = showOnForeground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        loadAd(placement, callbacks: callbacks)
    }

    public func disableAppOpenLifecycle() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        appOpenPlacement = nil
        shouldShowAppOpenOnForeground = false
    }

    @objc private func applicationDidBecomeActive() {
        guard shouldShowAppOpenOnForeground, !isShowingAppOpen, let placement = appOpenPlacement else { return }
        showAd(placement, callbacks: nil)
    }

    public func loadBanner(_ placement: AdPlacement, container: UIView, callbacks: AdCallbacks?) {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = placement.adUnitId
        banner.rootViewController = rootViewControllerProvider()
        attachPaidEventHandler(to: banner, placement: placement)
        let delegate = BannerDelegateBox(placement: placement, callbacks: callbacks)
        banner.delegate = delegate
        bannerDelegates[placement.placement] = delegate
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(banner)
        banner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        banner.load(Request())
    }

    public func loadNative(_ placement: AdPlacement, callbacks: NativeAdCallbacks?) {
        let delegate = NativeDelegateBox(placement: placement, callbacks: callbacks) { [weak self] nativeAd, placement in
            self?.attachPaidEventHandler(to: nativeAd, placement: placement)
        }
        let loader = AdLoader(
            adUnitID: placement.adUnitId,
            rootViewController: rootViewControllerProvider(),
            adTypes: [.native],
            options: nil
        )
        loader.delegate = delegate
        delegate.loader = loader
        nativeDelegates[placement.placement] = delegate
        loader.load(Request())
    }

    private func loadAppOpen(_ placement: AdPlacement) {
        let key = placement.cacheKey
        AppOpenAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            self.runOnMain {
                if let error {
                    self.finishLoadWithError(key: key, error: error)
                    return
                }
                guard let ad else {
                    self.finishLoadWithError(
                        key: key,
                        error: GrowthAnalyticsError.providerUnsupported("App open ad load returned nil")
                    )
                    return
                }
                self.appOpenAds[key] = ad
                self.finishLoadSuccessfully(key: key)
            }
        }
    }

    private func loadInterstitial(_ placement: AdPlacement) {
        let key = placement.cacheKey
        InterstitialAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            self.runOnMain {
                if let error {
                    self.finishLoadWithError(key: key, error: error)
                    return
                }
                guard let ad else {
                    self.finishLoadWithError(
                        key: key,
                        error: GrowthAnalyticsError.providerUnsupported("Interstitial ad load returned nil")
                    )
                    return
                }
                self.interstitialAds[key] = ad
                self.finishLoadSuccessfully(key: key)
            }
        }
    }

    private func loadRewarded(_ placement: AdPlacement) {
        let key = placement.cacheKey
        RewardedAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            self.runOnMain {
                if let error {
                    self.finishLoadWithError(key: key, error: error)
                    return
                }
                guard let ad else {
                    self.finishLoadWithError(
                        key: key,
                        error: GrowthAnalyticsError.providerUnsupported("Rewarded ad load returned nil")
                    )
                    return
                }
                self.rewardedAds[key] = ad
                self.finishLoadSuccessfully(key: key)
            }
        }
    }

    private func loadRewardedInterstitial(_ placement: AdPlacement) {
        let key = placement.cacheKey
        RewardedInterstitialAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            self.runOnMain {
                if let error {
                    self.finishLoadWithError(key: key, error: error)
                    return
                }
                guard let ad else {
                    self.finishLoadWithError(
                        key: key,
                        error: GrowthAnalyticsError.providerUnsupported("Rewarded interstitial ad load returned nil")
                    )
                    return
                }
                self.rewardedInterstitialAds[key] = ad
                self.finishLoadSuccessfully(key: key)
            }
        }
    }

    private func attachPaidEventHandler(to ad: AppOpenAd, placement: AdPlacement) {
        ad.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func attachPaidEventHandler(to ad: InterstitialAd, placement: AdPlacement) {
        ad.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func attachPaidEventHandler(to ad: RewardedAd, placement: AdPlacement) {
        ad.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func attachPaidEventHandler(to ad: RewardedInterstitialAd, placement: AdPlacement) {
        ad.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func attachPaidEventHandler(to banner: BannerView, placement: AdPlacement) {
        banner.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func attachPaidEventHandler(to nativeAd: NativeAd, placement: AdPlacement) {
        nativeAd.paidEventHandler = { [weak self] value in
            self?.reportPaidEvent(value, placement: placement)
        }
    }

    private func reportPaidEvent(_ value: AdValue, placement: AdPlacement) {
        let revenue = value.value.doubleValue / 1_000_000
        guard let payload = try? AdRevenuePayload(
            adPlatform: placement.adPlatform ?? "admob",
            mediationPlatform: "admob",
            adUnitId: placement.adUnitId,
            placement: placement.placement,
            adFormat: placement.format,
            currency: value.currencyCode,
            revenue: revenue,
            networkFirmId: placement.adPlatformId,
            scene: placement.placement,
            precision: precisionName(value.precision)
        ) else {
            return
        }
        revenueReporter(payload)
    }

    private func precisionName(_ precision: AdValuePrecision) -> String {
        switch precision {
        case .unknown: "unknown"
        case .estimated: "estimated"
        case .publisherProvided: "publisher_provided"
        case .precise: "precise"
        @unknown default: "unknown"
        }
    }

    private func prepareForPresentation(
        _ ad: FullScreenPresentingAd,
        key: AdCacheKey,
        placement: AdPlacement,
        callbacks: AdCallbacks?
    ) {
        fullScreenStates[key] = .showing
        presentingKeys.insert(key)
        callbacksByKey[key] = callbacks
        presentedAds[ObjectIdentifier(ad as AnyObject)] = PresentedAd(key: key, placement: placement)
    }

    private func presentedAd(for ad: FullScreenPresentingAd) -> PresentedAd? {
        presentedAds[ObjectIdentifier(ad as AnyObject)]
    }

    private func enqueueLoadCallback(
        key: AdCacheKey,
        placement: AdPlacement,
        callbacks: AdCallbacks?
    ) {
        guard let callbacks else { return }
        pendingLoadCallbacks[key, default: []].append(
            PendingLoadCallback(placement: placement, callbacks: callbacks)
        )
    }

    private func finishLoadSuccessfully(key: AdCacheKey) {
        fullScreenStates[key] = .loaded
        let callbacks = pendingLoadCallbacks.removeValue(forKey: key) ?? []
        callbacks.forEach { $0.callbacks.onLoaded($0.placement) }
    }

    private func finishLoadWithError(key: AdCacheKey, error: Error) {
        fullScreenStates[key] = .idle
        let callbacks = pendingLoadCallbacks.removeValue(forKey: key) ?? []
        callbacks.forEach { $0.callbacks.onFailed($0.placement, error: error) }
    }

    private func startNextLoad(_ item: PresentedAd) {
        if fullScreenStates[item.key] == .showing {
            fullScreenStates[item.key] = .idle
        }
        loadAdOnMain(item.placement, callbacks: nil)
    }

    private func finishPresentation(_ ad: FullScreenPresentingAd, item: PresentedAd) {
        presentedAds.removeValue(forKey: ObjectIdentifier(ad as AnyObject))
        presentingKeys.remove(item.key)
        callbacksByKey.removeValue(forKey: item.key)
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

extension AdMobAdProvider: FullScreenContentDelegate {
    public func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let item = presentedAd(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = true
        }
        callbacksByKey[item.key]?.onShown(item.placement)
        startNextLoad(item)
    }

    public func adDidRecordClick(_ ad: FullScreenPresentingAd) {
        guard let item = presentedAd(for: ad) else { return }
        callbacksByKey[item.key]?.onClicked(item.placement)
    }

    public func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        guard let item = presentedAd(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = false
        }
        callbacksByKey[item.key]?.onFailed(item.placement, error: error)
        startNextLoad(item)
        finishPresentation(ad, item: item)
    }

    public func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let item = presentedAd(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = false
        }
        callbacksByKey[item.key]?.onClosed(item.placement)
        if fullScreenStates[item.key] == .showing {
            startNextLoad(item)
        }
        finishPresentation(ad, item: item)
    }
}

private struct AdCacheKey: Hashable {
    let format: String
    let adUnitId: String
}

private extension AdPlacement {
    var cacheKey: AdCacheKey {
        AdCacheKey(format: format.rawValue, adUnitId: adUnitId)
    }
}

private struct PendingLoadCallback {
    let placement: AdPlacement
    let callbacks: AdCallbacks
}

private struct PresentedAd {
    let key: AdCacheKey
    let placement: AdPlacement
}

private enum AdLoadState {
    case idle
    case loading
    case loaded
    case showing
}

private final class BannerDelegateBox: NSObject, BannerViewDelegate {
    let placement: AdPlacement
    weak var callbacks: AdCallbacks?

    init(placement: AdPlacement, callbacks: AdCallbacks?) {
        self.placement = placement
        self.callbacks = callbacks
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        callbacks?.onLoaded(placement)
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        callbacks?.onFailed(placement, error: error)
    }

    func bannerViewDidRecordClick(_ bannerView: BannerView) {
        callbacks?.onClicked(placement)
    }
}

private final class NativeDelegateBox: NSObject, AdLoaderDelegate, NativeAdLoaderDelegate {
    let placement: AdPlacement
    weak var callbacks: NativeAdCallbacks?
    let paidEventHandler: (NativeAd, AdPlacement) -> Void
    var loader: AdLoader?

    init(placement: AdPlacement, callbacks: NativeAdCallbacks?, paidEventHandler: @escaping (NativeAd, AdPlacement) -> Void = { _, _ in }) {
        self.placement = placement
        self.callbacks = callbacks
        self.paidEventHandler = paidEventHandler
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        callbacks?.onFailed(placement, error: error)
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        paidEventHandler(nativeAd, placement)
        callbacks?.onLoaded(placement, nativeAd: nativeAd)
    }
}

public final class NexusAdMobNativeAdView: NativeAdView {
    private let iconImageView = UIImageView()
    private let headlineTextLabel = UILabel()
    private let bodyTextLabel = UILabel()
    private let callToActionButton = UIButton(type: .system)
    private let advertiserTextLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        buildView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    public func bind(_ nativeAd: NativeAd) {
        self.nativeAd = nativeAd
        headlineTextLabel.text = nativeAd.headline
        bodyTextLabel.text = nativeAd.body
        bodyTextLabel.isHidden = nativeAd.body?.isEmpty ?? true
        callToActionButton.setTitle(nativeAd.callToAction ?? "Open", for: .normal)
        callToActionButton.isHidden = nativeAd.callToAction?.isEmpty ?? true
        advertiserTextLabel.text = nativeAd.advertiser
        advertiserTextLabel.isHidden = nativeAd.advertiser?.isEmpty ?? true
        iconImageView.image = nativeAd.icon?.image
        iconImageView.isHidden = nativeAd.icon == nil
        callToActionButton.isUserInteractionEnabled = false
    }

    private func buildView() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true

        iconImageView.contentMode = .scaleAspectFill
        iconImageView.clipsToBounds = true
        iconImageView.layer.cornerRadius = 8
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        headlineTextLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headlineTextLabel.numberOfLines = 2

        bodyTextLabel.font = .systemFont(ofSize: 13)
        bodyTextLabel.textColor = .secondaryLabel
        bodyTextLabel.numberOfLines = 2

        advertiserTextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        advertiserTextLabel.textColor = .tertiaryLabel

        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.cornerStyle = .medium
        callToActionButton.configuration = buttonConfig

        let textStack = UIStackView(arrangedSubviews: [headlineTextLabel, bodyTextLabel, advertiserTextLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let topRow = UIStackView(arrangedSubviews: [iconImageView, textStack])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 10

        let rootStack = UIStackView(arrangedSubviews: [topRow, callToActionButton])
        rootStack.axis = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        headlineView = headlineTextLabel
        bodyView = bodyTextLabel
        callToActionView = callToActionButton
        iconView = iconImageView
        advertiserView = advertiserTextLabel

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            iconImageView.widthAnchor.constraint(equalToConstant: 48),
            iconImageView.heightAnchor.constraint(equalToConstant: 48)
        ])
    }
}
