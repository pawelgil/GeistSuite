import Darwin

struct OwnedDirectoryReceipt: Equatable {
    let canonicalPath: String
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
}
