// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NexusGrowthAnalyticsAdAdMobProvider",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "NexusGrowthAnalyticsAdAdMob", targets: ["NexusGrowthAnalyticsAdAdMob"])
    ],
    dependencies: [
        .package(url: "https://github.com/harden-l/nexus-sdk-ios.git", exact: "0.0.12"),
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "12.0.0")
    ],
    targets: [
        .target(
            name: "NexusGrowthAnalyticsAdAdMob",
            dependencies: [
                .product(name: "NexusGrowthAnalyticsAd", package: "nexus-sdk-ios"),
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads")
            ]
        )
    ]
)
