import Foundation

/// Registers the sqlite-vector SQLite extension so that vector SQL functions
/// (vector_full_scan, vector_quantize_scan, vector_init, etc.) are available
/// in every database connection opened after this call.
///
/// CURRENT STATUS: Stub — sqlite-vector package is not yet linked.
///
/// To fully activate sqlite-vector:
/// 1. Add `sqlite-vector` to project.yml:
///      url: https://github.com/sqliteai/sqlite-vector, from: "0.9.95"
/// 2. Switch GRDB to a custom SQLite build without SQLITE_OMIT_LOAD_EXTENSION:
///    https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md
/// 3. In `setup()` below, uncomment:
///      sqlite3_auto_extension(sqlite3VectorInit)
/// 4. In DatabaseManager.setup(), add to prepareDatabase:
///      SELECT vector_init('clip_embeddings', 'embedding',
///                         'type=FLOAT32,dimension=256,distance=COSINE')
///
/// Without the extension, EmbeddingStore falls back to Swift-side cosine
/// similarity (brute-force, exact, correct for all dataset sizes).
enum VectorExtensionLoader {

    /// True once `setup()` has confirmed the extension is available.
    private(set) static var isLoaded = false

    /// Call once in AppDelegate.applicationDidFinishLaunching, before any
    /// DatabaseQueue/DatabasePool is opened (before DatabaseManager.shared is accessed).
    static func setup() {
        // When sqlite-vector is linked as a Swift package its entry point is
        // `sqlite3VectorInit`. Passing it to sqlite3_auto_extension registers it
        // for every subsequent database connection — no dynamic loading required.
        //
        // Uncomment when the package is available and GRDB uses custom SQLite:
        // sqlite3_auto_extension(sqlite3VectorInit)
        // isLoaded = true
    }
}
