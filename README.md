# Nexus AdMob Provider

Google Mobile Ads Provider for `NexusGrowthAnalyticsAd`.

## Swift Package Manager

Add this package and select the `NexusGrowthAnalyticsAdAdMob` product:

```text
https://github.com/harden-l/nexus-sdk-ios-admob-provider.git
```

Configure `GADApplicationIdentifier` and Google's current `SKAdNetworkItems` in the host App, then initialize the provider:

```swift
import NexusGrowthAnalyticsAd
import NexusGrowthAnalyticsAdAdMob

let adMob = AdMobAdProvider(
    rootViewControllerProvider: { rootViewController },
    revenueReporter: { payload in
        _ = try? NexusGrowthAnalyticsAd.shared.reportAdRevenue(payload)
    }
)
NexusGrowthAnalyticsAd.shared.initialize(
    config: try AnalyticsConfig(productId: "<PRODUCT_ID>"),
    adProvider: adMob
)
```

The provider version is aligned with the Nexus iOS SDK version.

Full-screen ads are cached by `format + adUnitId`. Duplicate loads are coalesced, a cache miss during `showAd` starts loading for the next attempt, and the provider automatically preloads the next ad after a successful or failed presentation.
