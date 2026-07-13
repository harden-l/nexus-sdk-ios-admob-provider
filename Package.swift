// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NexusGrowthAnalyticsAdAdMobProvider",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "NexusGrowthAnalyticsAdAdMob", targets: ["NexusGrowthAnalyticsAdAdMob"])
    ],
    dependencies: [
        .package(name: "NexusSDK", path: "../.."),
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "12.0.0")
    ],
    targets: [
        .target(
            name: "NexusGrowthAnalyticsAdAdMob",
            dependencies: [
                .product(name: "NexusGrowthAnalyticsAd", package: "NexusSDK"),
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads")
            ]
        )
    ]
)
