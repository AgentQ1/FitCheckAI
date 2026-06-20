// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FitCheckAI",
    platforms: [.iOS(.v17)],
    license: .mit,
    dependencies: [
        // Firebase: Auth, Firestore, Storage
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            from: "11.0.0"
        ),
        // Google Sign-In
        .package(
            url: "https://github.com/google/GoogleSignIn-iOS.git",
            from: "8.0.0"
        ),
    ],
    targets: [
        .target(
            name: "FitCheckAI",
            dependencies: [
                .product(name: "FirebaseAuth",             package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore",        package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage",          package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn",             package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift",        package: "GoogleSignIn-iOS"),
            ]
        ),
    ]
)
