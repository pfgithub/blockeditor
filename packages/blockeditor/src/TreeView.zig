// The tree view lists the root block, all orphaned blocks (blocks with no parent but with
// backreferences), and all deleted blocks (blocks with no parent and nothing in its backreference
// tree has a parent) (these are automatically deleted after 30 days)

// In the down arrow, it lists every referenced block

// To start, blocks will be initialized from the filesystem tree. All files will be TexteditorBlocks. All folders will be FolderBlocks.
