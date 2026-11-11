/// Kind of local mutation an operation delivers.
enum SyncOperationType {
  /// A new entity was created locally.
  create,

  /// An existing entity was modified locally.
  update,

  /// An entity was deleted locally.
  delete,
}
