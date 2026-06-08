import Foundation
import UIKit
import FirebaseFirestore
import FirebaseStorage

// MARK: - Upgrade History Service
//
// Persists, fetches, saves, and prunes the AI outfit-upgrade history that is tied to
// each specific outfit analysis. Storage layout (analysisId == fitCheckID):
//
//   users/{uid}/fit_checks/{analysisId}                                  ← the analysis
//   users/{uid}/fit_checks/{analysisId}/generatedUpgrades/{upgradeId}    ← upgrade history
//   users/{uid}/savedUpgrades/{upgradeId}                               ← saved (never pruned)
//
// Storage caps keep this bounded so storage never grows forever:
//   • Config.maxGeneratedUpgrades per analysis
//   • Config.maxHistoryItems analyses per user
// Saved upgrades live in their own top-level collection and survive all cleanup.
//
// All methods are best-effort and log every step under the "[UpgradeHistory]" prefix.
enum UpgradeHistoryService {

    private static var db: Firestore { Firestore.firestore() }
    private static var storage: Storage { Storage.storage() }
    private static let tag = "[UpgradeHistory]"

    private static func upgradesRef(_ uid: String, _ analysisId: String) -> CollectionReference {
        db.collection("users").document(uid)
            .collection("fit_checks").document(analysisId)
            .collection("generatedUpgrades")
    }

    // MARK: - Save a freshly generated upgrade

    /// Persists one successful upgrade under its analysis. Gemini results (in-memory
    /// bytes) are uploaded to Storage first; OpenAI results already live in Storage and
    /// reuse a STABLE document id so re-views never create duplicate history entries.
    /// Returns the persisted model, or nil on failure.
    @discardableResult
    static func saveGeneratedUpgrade(
        uid: String,
        analysisId: String,
        provider: UpgradeProviderKind,
        image: UpgradeImageSource,
        promptUsed: String,
        generationTime: TimeInterval?,
        variationIndex: Int,
        sourceImageURL: String?
    ) async -> GeneratedUpgrade? {
        guard !analysisId.isEmpty else {
            print("\(tag) ⚠️ saveGeneratedUpgrade skipped — empty analysisId")
            return nil
        }

        // Stored as a plain slot tag ("stylea"/"styleb"); not shown in the UI.
        let providerName = provider.rawValue.lowercased()
        let imageURL: String
        var imageStoragePath: String?
        let upgradeId: String

        switch image {
        case .remote(let url):
            // Already-hosted image (e.g. a Storage URL). Use a stable id so re-views
            // overwrite rather than duplicate.
            imageURL = url.absoluteString
            imageStoragePath = nil
            upgradeId = "\(providerName)-preview"

        case .data(let data):
            // Gemini bytes: upload to our own Storage path and use a tokenized
            // download URL. Each generation is a genuinely new history entry.
            upgradeId = UUID().uuidString
            let path = "users/\(uid)/fit-checks/\(analysisId)/generatedUpgrades/\(upgradeId).jpg"
            do {
                let ref = storage.reference(withPath: path)
                let meta = StorageMetadata()
                meta.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: meta)
                let url = try await ref.downloadURL()
                imageURL = url.absoluteString
                imageStoragePath = path
                print("\(tag) 💾 generated image saved path=\(path) bytes=\(data.count)")
            } catch {
                print("\(tag) ❌ Gemini image upload failed at \(path): \(error.localizedDescription)")
                return nil
            }
        }

        // NOTE: `isSaved` is intentionally omitted from this merge write so that a
        // later auto-persist of the same (stable-id) OpenAI doc never clobbers a
        // Save the user already made. Absent → reads back as false.
        var docData: [String: Any] = [
            "upgradeId": upgradeId,
            "imageURL": imageURL,
            "providerName": providerName,
            "promptUsed": promptUsed,
            "createdAt": FieldValue.serverTimestamp(),
            "variationIndex": variationIndex,
            "sourceAnalysisId": analysisId,
            "status": "success",
        ]
        if let imageStoragePath { docData["imageStoragePath"] = imageStoragePath }
        if let sourceImageURL { docData["sourceImageURL"] = sourceImageURL }
        if let generationTime { docData["generationTimeMs"] = Int(generationTime * 1000) }

        do {
            try await upgradesRef(uid, analysisId).document(upgradeId).setData(docData, merge: true)
            print("\(tag) ✅ generated upgrade saved — analysisId=\(analysisId) upgradeId=\(upgradeId) provider=\(providerName)")
        } catch {
            print("\(tag) ❌ Firestore write failed for upgradeId=\(upgradeId): \(error.localizedDescription)")
            return nil
        }

        return GeneratedUpgrade(
            id: upgradeId,
            imageURL: imageURL,
            imageStoragePath: imageStoragePath,
            providerName: providerName,
            promptUsed: promptUsed,
            createdAt: Date(),
            variationIndex: variationIndex,
            sourceAnalysisId: analysisId,
            sourceImageURL: sourceImageURL,
            isSaved: false,
            generationTimeMs: generationTime.map { Int($0 * 1000) },
            status: "success"
        )
    }

    // MARK: - Fetch upgrade history for one analysis

    /// Newest-first generated upgrades for an analysis, capped at Config.maxGeneratedUpgrades.
    static func fetchGeneratedUpgrades(uid: String, analysisId: String) async throws -> [GeneratedUpgrade] {
        let snap = try await upgradesRef(uid, analysisId)
            .order(by: "createdAt", descending: true)
            .limit(to: Config.maxGeneratedUpgrades)
            .getDocuments()
        let items = snap.documents.compactMap { GeneratedUpgrade(documentID: $0.documentID, data: $0.data()) }
        print("\(tag) 📥 fetched generatedUpgrades count=\(items.count) for analysisId=\(analysisId)")
        return items
    }

    // MARK: - Save (bookmark) an upgrade

    /// Marks a generated upgrade as saved and copies a durable reference into the
    /// user's top-level `savedUpgrades` collection (which cleanup never touches).
    static func saveUpgrade(uid: String, upgrade: GeneratedUpgrade, originalImageURL: String?) async throws {
        print("\(tag) 🔖 save tapped upgradeId=\(upgrade.id) analysisId=\(upgrade.sourceAnalysisId)")

        // 1) Flag the source upgrade so cleanup preserves it.
        try await upgradesRef(uid, upgrade.sourceAnalysisId)
            .document(upgrade.id)
            .setData(["isSaved": true], merge: true)

        // 2) Durable copy under savedUpgrades.
        var data: [String: Any] = [
            "upgradeId": upgrade.id,
            "imageURL": upgrade.imageURL,
            "sourceAnalysisId": upgrade.sourceAnalysisId,
            "providerName": upgrade.providerName,
            "promptUsed": upgrade.promptUsed,
            "createdAt": Timestamp(date: upgrade.createdAt),
            "savedAt": FieldValue.serverTimestamp(),
        ]
        if let p = upgrade.imageStoragePath { data["imageStoragePath"] = p }
        if let o = originalImageURL ?? upgrade.sourceImageURL { data["originalImageURL"] = o }

        do {
            try await db.collection("users").document(uid)
                .collection("savedUpgrades").document(upgrade.id)
                .setData(data, merge: true)
            print("\(tag) ✅ savedUpgrades write success upgradeId=\(upgrade.id)")
        } catch {
            print("\(tag) ❌ savedUpgrades write failure upgradeId=\(upgrade.id): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cleanup: generated upgrades for one analysis

    /// Keeps the newest Config.maxGeneratedUpgrades upgrades for an analysis and deletes
    /// older UNSAVED ones (doc + Storage file). Saved upgrades are always preserved.
    static func cleanupGeneratedUpgrades(uid: String, analysisId: String) async {
        guard !analysisId.isEmpty else { return }
        do {
            let snap = try await upgradesRef(uid, analysisId)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            guard snap.documents.count > Config.maxGeneratedUpgrades else { return }

            let stale = snap.documents.dropFirst(Config.maxGeneratedUpgrades)
            var deleted = 0, storageDeleted = 0
            for doc in stale {
                let data = doc.data()
                if data["isSaved"] as? Bool == true { continue } // never prune saved
                if let path = data["imageStoragePath"] as? String, !path.isEmpty {
                    do { try await storage.reference(withPath: path).delete(); storageDeleted += 1 }
                    catch { print("\(tag) ⚠️ storage delete failed \(path): \(error.localizedDescription)") }
                }
                try? await doc.reference.delete()
                deleted += 1
            }
            print("\(tag) 🧹 generated upgrades cleanup analysisId=\(analysisId) deleted=\(deleted) storageFiles=\(storageDeleted)")
        } catch {
            print("\(tag) ❌ cleanupGeneratedUpgrades error analysisId=\(analysisId): \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup: analysis history for the user

    /// Keeps the newest Config.maxHistoryItems analyses and deletes everything beyond
    /// the cap — including each removed analysis's generatedUpgrades subcollection and
    /// original Storage image. UNSAVED upgrade images are deleted; saved ones (and the
    /// `savedUpgrades` collection) are always preserved.
    ///
    /// Pruning is intentionally cap-based only: the History grid shows the latest
    /// Config.maxHistoryItems regardless of age, so age-based deletion of those visible
    /// items would yank a row out from under a tap. Config.historyMaxAgeDays is kept as
    /// the documented retention intent; among items beyond the cap, age is moot (they're
    /// removed anyway).
    static func cleanupUserAnalysisHistory(uid: String) async {
        do {
            let snap = try await db.collection("users").document(uid)
                .collection("fit_checks")
                .order(by: "createdAt", descending: true)
                .getDocuments()

            let docs = snap.documents
            print("\(tag) 🧮 history cleanup — analyses found=\(docs.count)")
            guard docs.count > Config.maxHistoryItems else {
                print("\(tag) 🧮 history cleanup — kept=\(docs.count) deleted=0")
                return
            }

            var deleted = 0
            for doc in docs.dropFirst(Config.maxHistoryItems) {
                await deleteAnalysisCompletely(uid: uid, analysisId: doc.documentID, data: doc.data())
                deleted += 1
            }
            print("\(tag) 🧮 history cleanup — kept=\(docs.count - deleted) deleted=\(deleted)")
        } catch {
            print("\(tag) ❌ cleanupUserAnalysisHistory error: \(error.localizedDescription)")
        }
    }

    /// Deletes one analysis: its generatedUpgrades subcollection (UNSAVED images +
    /// every subdoc), its original Storage image, then the analysis document itself.
    private static func deleteAnalysisCompletely(uid: String, analysisId: String, data: [String: Any]) async {
        var storageDeleted = 0
        var upgradesDeleted = 0

        // 1) generatedUpgrades subcollection
        if let subSnap = try? await upgradesRef(uid, analysisId).getDocuments() {
            for d in subSnap.documents {
                let sd = d.data()
                let saved = sd["isSaved"] as? Bool ?? false
                // Preserve the Storage image of saved upgrades — savedUpgrades references it.
                if !saved, let path = sd["imageStoragePath"] as? String, !path.isEmpty {
                    do { try await storage.reference(withPath: path).delete(); storageDeleted += 1 }
                    catch { print("\(tag) ⚠️ storage delete failed \(path): \(error.localizedDescription)") }
                }
                try? await d.reference.delete()
                upgradesDeleted += 1
            }
        }

        // 2) original uploaded photo
        if let original = data["storagePath"] as? String, !original.isEmpty {
            do { try await storage.reference(withPath: original).delete(); storageDeleted += 1 }
            catch { print("\(tag) ⚠️ original storage delete failed \(original): \(error.localizedDescription)") }
        }

        // 3) the analysis document
        do {
            try await db.collection("users").document(uid)
                .collection("fit_checks").document(analysisId).delete()
            print("\(tag) 🗑️ deleted analysisId=\(analysisId) generatedUpgrades=\(upgradesDeleted) storageFiles=\(storageDeleted)")
        } catch {
            print("\(tag) ❌ failed to delete analysisId=\(analysisId): \(error.localizedDescription)")
        }
    }
}
