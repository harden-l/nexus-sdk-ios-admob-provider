import Foundation
import GoogleMobileAds
import NexusGrowthAnalyticsAd
import UIKit

public final class AdMobAdProvider: NSObject, AdProvider, @unchecked Sendable {
    private let rootViewControllerProvider: @Sendable () -> UIViewController?
    private let revenueReporter: @Sendable (AdRevenuePayload) -> Void
    private var appOpenAds: [String: AppOpenAd] = [:]
    private var interstitialAds: [String: InterstitialAd] = [:]
    private var rewardedAds: [String: RewardedAd] = [:]
    private var rewardedInterstitialAds: [String: RewardedInterstitialAd] = [:]
    private var appOpenPlacement: AdPlacement?
    private var shouldShowAppOpenOnForeground = false
    private var isShowingAppOpen = false
    private var callbacksByPlacement: [String: AdCallbacks] = [:]
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
        switch placement.format {
        case .appOpen:
            loadAppOpen(placement, callbacks: callbacks)
        case .interstitial:
            loadInterstitial(placement, callbacks: callbacks)
        case .rewarded:
            loadRewarded(placement, callbacks: callbacks)
        case .rewardedInterstitial:
            loadRewardedInterstitial(placement, callbacks: callbacks)
        case .banner, .native:
            callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Use loadBanner/loadNative for \(placement.format.rawValue)"))
        }
    }

    public func showAd(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        let root = rootViewControllerProvider()
        switch placement.format {
        case .appOpen:
            guard let ad = appOpenAds[placement.placement] else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("App open ad is not loaded"))
                loadAppOpen(placement, callbacks: nil)
                return
            }
            callbacksByPlacement[placement.placement] = callbacks
            ad.fullScreenContentDelegate = self
            ad.present(from: root)
        case .interstitial:
            guard let ad = interstitialAds[placement.placement] else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Interstitial ad is not loaded"))
                loadInterstitial(placement, callbacks: nil)
                return
            }
            callbacksByPlacement[placement.placement] = callbacks
            ad.fullScreenContentDelegate = self
            ad.present(from: root)
        case .rewarded, .rewardedInterstitial:
            if placement.format == .rewardedInterstitial {
                guard let ad = rewardedInterstitialAds[placement.placement] else {
                    callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded interstitial ad is not loaded"))
                    loadRewardedInterstitial(placement, callbacks: nil)
                    return
                }
                callbacksByPlacement[placement.placement] = callbacks
                ad.fullScreenContentDelegate = self
                ad.present(from: root) { [weak callbacks] in
                    callbacks?.onReward(placement)
                }
                return
            }
            guard let ad = rewardedAds[placement.placement] else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded ad is not loaded"))
                loadRewarded(placement, callbacks: nil)
                return
            }
            callbacksByPlacement[placement.placement] = callbacks
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
        loadAppOpen(placement, callbacks: callbacks)
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

    private func loadAppOpen(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        AppOpenAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            if let error {
                callbacks?.onFailed(placement, error: error)
                return
            }
            guard let ad else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("App open ad load returned nil"))
                return
            }
            self.attachPaidEventHandler(to: ad, placement: placement)
            self.appOpenAds[placement.placement] = ad
            callbacks?.onLoaded(placement)
        }
    }

    private func loadInterstitial(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        InterstitialAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            if let error {
                callbacks?.onFailed(placement, error: error)
                return
            }
            guard let ad else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Interstitial ad load returned nil"))
                return
            }
            self.attachPaidEventHandler(to: ad, placement: placement)
            self.interstitialAds[placement.placement] = ad
            callbacks?.onLoaded(placement)
        }
    }

    private func loadRewarded(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        RewardedAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            if let error {
                callbacks?.onFailed(placement, error: error)
                return
            }
            guard let ad else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded ad load returned nil"))
                return
            }
            self.attachPaidEventHandler(to: ad, placement: placement)
            self.rewardedAds[placement.placement] = ad
            callbacks?.onLoaded(placement)
        }
    }

    private func loadRewardedInterstitial(_ placement: AdPlacement, callbacks: AdCallbacks?) {
        RewardedInterstitialAd.load(with: placement.adUnitId, request: Request()) { [weak self] ad, error in
            guard let self else { return }
            if let error {
                callbacks?.onFailed(placement, error: error)
                return
            }
            guard let ad else {
                callbacks?.onFailed(placement, error: GrowthAnalyticsError.providerUnsupported("Rewarded interstitial ad load returned nil"))
                return
            }
            self.attachPaidEventHandler(to: ad, placement: placement)
            self.rewardedInterstitialAds[placement.placement] = ad
            callbacks?.onLoaded(placement)
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

    private func placement(for ad: FullScreenPresentingAd) -> (key: String, placement: AdPlacement)? {
        if let appOpen = ad as? AppOpenAd,
           let pair = appOpenAds.first(where: { $0.value === appOpen }) {
            guard let placement = try? AdPlacement(placement: pair.key, adUnitId: appOpen.adUnitID, format: .appOpen) else { return nil }
            return (pair.key, placement)
        }
        if let interstitial = ad as? InterstitialAd,
           let pair = interstitialAds.first(where: { $0.value === interstitial }) {
            guard let placement = try? AdPlacement(placement: pair.key, adUnitId: interstitial.adUnitID, format: .interstitial) else { return nil }
            return (pair.key, placement)
        }
        if let rewarded = ad as? RewardedAd,
           let pair = rewardedAds.first(where: { $0.value === rewarded }) {
            guard let placement = try? AdPlacement(placement: pair.key, adUnitId: rewarded.adUnitID, format: .rewarded) else { return nil }
            return (pair.key, placement)
        }
        if let rewardedInterstitial = ad as? RewardedInterstitialAd,
           let pair = rewardedInterstitialAds.first(where: { $0.value === rewardedInterstitial }) {
            guard let placement = try? AdPlacement(placement: pair.key, adUnitId: rewardedInterstitial.adUnitID, format: .rewardedInterstitial) else { return nil }
            return (pair.key, placement)
        }
        return nil
    }
}

extension AdMobAdProvider: FullScreenContentDelegate {
    public func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let item = placement(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = true
        }
        callbacksByPlacement[item.key]?.onShown(item.placement)
    }

    public func adDidRecordClick(_ ad: FullScreenPresentingAd) {
        guard let item = placement(for: ad) else { return }
        callbacksByPlacement[item.key]?.onClicked(item.placement)
    }

    public func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        guard let item = placement(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = false
        }
        callbacksByPlacement[item.key]?.onFailed(item.placement, error: error)
        reloadAfterFullscreen(item.placement)
    }

    public func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let item = placement(for: ad) else { return }
        if item.placement.format == .appOpen {
            isShowingAppOpen = false
        }
        callbacksByPlacement[item.key]?.onClosed(item.placement)
        reloadAfterFullscreen(item.placement)
    }

    private func reloadAfterFullscreen(_ placement: AdPlacement) {
        switch placement.format {
        case .appOpen:
            appOpenAds.removeValue(forKey: placement.placement)
            loadAppOpen(placement, callbacks: nil)
        case .interstitial:
            interstitialAds.removeValue(forKey: placement.placement)
            loadInterstitial(placement, callbacks: nil)
        case .rewarded:
            rewardedAds.removeValue(forKey: placement.placement)
            loadRewarded(placement, callbacks: nil)
        case .rewardedInterstitial:
            rewardedInterstitialAds.removeValue(forKey: placement.placement)
            loadRewardedInterstitial(placement, callbacks: nil)
        case .banner, .native:
            break
        }
    }
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
