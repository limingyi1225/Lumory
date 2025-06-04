import CoreData

struct PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentCloudKitContainer

    init() {
        // 创建容器，名称必须与 .xcdatamodeld 文件名匹配
        container = NSPersistentCloudKitContainer(name: "Model")
        
        // 配置 iCloud container identifier，请替换为你在 Xcode Entitlements 中填写的值
        let options = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.Mingyi.Lumory")
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("无法获取 persistentStoreDescriptions")
        }
        description.cloudKitContainerOptions = options
        
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
} 