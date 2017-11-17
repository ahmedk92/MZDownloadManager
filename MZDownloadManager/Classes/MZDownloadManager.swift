//
//  MZDownloadManager.swift
//  MZDownloadManager
//
//  Created by Muhammad Zeeshan on 19/04/2016.
//  Copyright © 2016 ideamakerz. All rights reserved.
//

import UIKit
import Dispatch

fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

fileprivate func > <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l > r
  default:
    return rhs < lhs
  }
}


@objc public protocol MZDownloadManagerDelegate: class {
    /**A delegate method called each time whenever any download task's progress is updated
     */
    func downloadRequestDidUpdateProgress(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called when interrupted tasks are repopulated
     */
    func downloadRequestDidPopulatedInterruptedTasks(_ downloadModel: [MZDownloadModel])
    /**A delegate method called each time whenever new download task is start downloading
     */
    @objc optional func downloadRequestStarted(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever running download task is paused. If task is already paused the action will be ignored
     */
    @objc optional func downloadRequestDidPaused(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever any download task is resumed. If task is already downloading the action will be ignored
     */
    @objc optional func downloadRequestDidResumed(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever any download task is resumed. If task is already downloading the action will be ignored
     */
    @objc optional func downloadRequestDidRetry(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever any download task is cancelled by the user
     */
    @objc optional func downloadRequestCanceled(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever any download task is finished successfully
     */
    @objc optional func downloadRequestFinished(_ downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever any download task is failed due to any reason
     */
    @objc optional func downloadRequestDidFailedWithError(_ error: NSError, downloadModel: MZDownloadModel, index: Int)
    /**A delegate method called each time whenever specified destination does not exists. It will be called on the session queue. It provides the opportunity to handle error appropriately
     */
    @objc optional func downloadRequestDestinationDoestNotExists(_ downloadModel: MZDownloadModel, index: Int, location: URL)
    /**
    * A delegate method called each time whenever any download task is creating a new request
    */
    @objc optional func downloadRequestShouldCreateRequest(_ url: URL) -> URLRequest
}

open class MZDownloadManager: NSObject {

    fileprivate var sessionManager: URLSession!
    
    fileprivate var backgroundSessionCompletionHandler: (() -> Void)?
    
    fileprivate let TaskDescFileNameIndex = 0
    fileprivate let TaskDescFileURLIndex = 1
    fileprivate let TaskDescFileDestinationIndex = 2
    
    fileprivate weak var delegate: MZDownloadManagerDelegate?
    
    open var downloadingArray: [MZDownloadModel] = []
    open let syncQueue: DispatchQueue = DispatchQueue(label: "MZDownloadManager", attributes: .concurrent)
    
    public convenience init(session sessionConfiguration: URLSessionConfiguration, delegate: MZDownloadManagerDelegate) {
        self.init()
        
        self.delegate = delegate
        self.sessionManager = backgroundSession(sessionConfiguration: sessionConfiguration)
        self.populateOtherDownloadTasks()

    }
    
    public convenience init(session sessionIdentifer: String, delegate: MZDownloadManagerDelegate, completion: (() -> Void)?) {
        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: sessionIdentifer)
        self.init(session: sessionConfiguration, delegate: delegate)

        self.backgroundSessionCompletionHandler = completion
    }

    public convenience init(configure sessionConfiguration: URLSessionConfiguration, delegate: MZDownloadManagerDelegate, completion: (() -> Void)?) {
        self.init(session: sessionConfiguration, delegate: delegate)
        self.backgroundSessionCompletionHandler = completion
    }
    
    fileprivate func backgroundSession(sessionConfiguration: URLSessionConfiguration) -> URLSession {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 30;

        let session = Foundation.URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: queue)
        return session
    }
}

// MARK: Private Helper functions

extension MZDownloadManager {

    fileprivate func downloadTasks() -> [URLSessionDownloadTask] {
        var tasks: [URLSessionDownloadTask] = []
        let semaphore : DispatchSemaphore = DispatchSemaphore(value: 0)
        sessionManager.getTasksWithCompletionHandler { (dataTasks, uploadTasks, downloadTasks) -> Void in
            tasks = downloadTasks
            semaphore.signal()
        }
        
        let _ = semaphore.wait(timeout: DispatchTime.distantFuture)
        
        debugPrint("MZDownloadManager: pending tasks \(tasks)")
        
        return tasks
    }
    
    fileprivate func populateOtherDownloadTasks() {
        let downloadTasks = self.downloadTasks()

        for downloadTask in downloadTasks {
            if let taskDescription = downloadTask.taskDescription {
                let taskDescComponents: [String] = taskDescription.components(separatedBy: ",")
                let fileName = taskDescComponents[TaskDescFileNameIndex]
                let fileURL = taskDescComponents[TaskDescFileURLIndex]
                let destinationPath = taskDescComponents[TaskDescFileDestinationIndex]

                let downloadModel = MZDownloadModel.init(fileName: fileName, fileURL: fileURL, destinationPath: destinationPath)
                downloadModel.task = downloadTask
                downloadModel.startTime = Date()

                if downloadTask.state == .running {
                    downloadModel.status = TaskStatus.downloading.description()
                    syncQueue.sync { downloadingArray.append(downloadModel) }
                } else if(downloadTask.state == .suspended) {
                    downloadModel.status = TaskStatus.paused.description()
                    syncQueue.sync { downloadingArray.append(downloadModel) }
                } else {
                    downloadModel.status = TaskStatus.failed.description()
                }
            }
        }
    }

    fileprivate func createRequest(_ url: URL) -> URLRequest {

        guard let request = self.delegate?.downloadRequestShouldCreateRequest?(url) else {
            return URLRequest(url: url)
        }

        return request
    }
    
    fileprivate func isValidResumeData(_ resumeData: Data?) -> Bool {
        
        guard let resumeData = resumeData, resumeData.count > 0 else {
            return false
        }
        
        do {
            let resumeDictionary : AnyObject = try PropertyListSerialization.propertyList(from: resumeData, options: PropertyListSerialization.MutabilityOptions(), format: nil) as AnyObject

            let localFilePath = resumeDictionary["NSURLSessionResumeInfoLocalPath"] as? String
            let tempFile = resumeDictionary["NSURLSessionResumeInfoTempFileName"] as? String

            if let localFilePath = localFilePath,
               localFilePath.characters.count > 0 {

                debugPrint("resume data file exists: \(FileManager.default.fileExists(atPath: localFilePath))")
                return FileManager.default.fileExists(atPath: localFilePath)
            } else if let tempFile = tempFile {

                let localFilePath = (NSTemporaryDirectory() as String) + tempFile
                debugPrint("resume data file exists: \(FileManager.default.fileExists(atPath: localFilePath))")
                return FileManager.default.fileExists(atPath: localFilePath)
            }

            return false
        } catch let error as NSError {
            debugPrint("resume data is nil: \(error)")
            return false
        }
    }
}

extension MZDownloadManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let downloadModel = self.model(withTask: downloadTask) {

            let receivedBytesCount = Double(downloadTask.countOfBytesReceived)
            let totalBytesCount = Double(downloadTask.countOfBytesExpectedToReceive)
            let progress = totalBytesCount > 0 ? Float(receivedBytesCount / totalBytesCount) : 0

            var timeInterval: TimeInterval = 0
            if let interval = downloadModel.startTime?.timeIntervalSinceNow {
                timeInterval = interval
            }
            let downloadTime = TimeInterval(-1 * timeInterval)

            let speed = downloadTime > 0 ? Float(totalBytesWritten) / Float(downloadTime) : 0

            let remainingContentLength = totalBytesExpectedToWrite - totalBytesWritten

            let remainingTime = speed > 0 ? remainingContentLength / Int64(speed) : 0
            let hours = Int(remainingTime) / 3600
            let minutes = (Int(remainingTime) - hours * 3600) / 60
            let seconds = Int(remainingTime) - hours * 3600 - minutes * 60

            let totalFileSize = MZUtility.calculateFileSizeInUnit(totalBytesExpectedToWrite)
            let totalFileSizeUnit = MZUtility.calculateUnit(totalBytesExpectedToWrite)

            let downloadedFileSize = MZUtility.calculateFileSizeInUnit(totalBytesWritten)
            let downloadedSizeUnit = MZUtility.calculateUnit(totalBytesWritten)

            let speedSize = MZUtility.calculateFileSizeInUnit(Int64(speed))
            let speedUnit = MZUtility.calculateUnit(Int64(speed))

            downloadModel.remainingTime = (hours, minutes, seconds)
            downloadModel.file = (totalFileSize, totalFileSizeUnit as String)
            downloadModel.downloadedFile = (downloadedFileSize, downloadedSizeUnit as String)
            downloadModel.speed = (speedSize, speedUnit as String)
            downloadModel.progress = progress
            if let index = self.index(ofModel: downloadModel) {
                syncQueue.sync {
                    self.downloadingArray[index] = downloadModel
                }
                self.delegate?.downloadRequestDidUpdateProgress(downloadModel, index: index)
            }
        }
    }

    fileprivate func index(ofModel model: MZDownloadModel) -> Int? {
        var modelIndex: Int? = nil
        syncQueue.sync {
            let index = self.downloadingArray.index(of: model)
            if let index = index, self.downloadingArray.count > index {
                modelIndex = index
            }
        }
        return modelIndex
    }

    fileprivate func model(atIndex index: Int) -> MZDownloadModel? {
        return syncQueue.sync { self.downloadingArray.count > index ? self.downloadingArray[index] : nil }
    }


    fileprivate func model(withTask task: URLSessionTask) -> MZDownloadModel? {
        var model: MZDownloadModel? = nil
        syncQueue.sync {
            let downloadingList = self.downloadingArray
            for (_, object) in downloadingList.enumerated() {
                let downloadModel = object
                if task.isEqual(downloadModel.task) {
                    model = downloadModel
                    break
                }
            }
        }
        return model
    }


    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {

        if let downloadModel = self.model(withTask: downloadTask) {
            if let response = downloadTask.response as? HTTPURLResponse,
               let url = response.url?.absoluteString, response.statusCode >= 400 {
                let error = NSError(domain: url, code: response.statusCode, userInfo: nil)

                if let index = self.index(ofModel: downloadModel) {
                    self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: downloadModel, index: index)
                }
                return
            }

            let fileName = downloadModel.fileName as NSString
            let basePath = downloadModel.destinationPath == "" ? MZUtility.baseFilePath : downloadModel.destinationPath
            let destinationPath = (basePath as NSString).appendingPathComponent(fileName as String)

            let fileManager : FileManager = FileManager.default

            //If all set just move downloaded file to the destination
            if fileManager.fileExists(atPath: basePath) {
                let fileURL = URL(fileURLWithPath: destinationPath as String)
                debugPrint("directory path = \(destinationPath)")

                do {
                    if fileManager.fileExists(atPath:destinationPath as String) {
                        try fileManager.removeItem(at:fileURL)
                    }
                    try fileManager.moveItem(at: location, to: fileURL)
                } catch let error as NSError {
                    debugPrint("Error while moving downloaded file to destination path:\(error)")
                    if let index = self.index(ofModel: downloadModel) {
                        self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: downloadModel, index: index)
                    }
                }
            } else {
                //Opportunity to handle the folder doesnot exists error appropriately.
                //Move downloaded file to destination
                //Delegate will be called on the session queue
                //Otherwise blindly give error Destination folder does not exists

                if let index = self.index(ofModel: downloadModel) {
                    if let _ = self.delegate?.downloadRequestDestinationDoestNotExists {
                        self.delegate?.downloadRequestDestinationDoestNotExists?(downloadModel, index: index, location: location)
                    } else {
                        let error = NSError(domain: "FolderDoesNotExist", code: 404, userInfo: [NSLocalizedDescriptionKey: "Destination folder does not exists"])
                        self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: downloadModel, index: index)
                    }
                }
            }
        }
    }

    @objc(URLSession:task:didCompleteWithError:)
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        debugPrint("task id: \(task.taskIdentifier)")
        /***** Any interrupted tasks due to any reason will be populated in failed state after init *****/

        var error: NSError? = error as NSError?
        if let response = task.response as? HTTPURLResponse,
           let url = response.url?.absoluteString, response.statusCode >= 400 {
            error = NSError(domain: url, code: response.statusCode, userInfo: nil)
        }

        if (error?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? NSNumber)?.intValue == NSURLErrorCancelledReasonUserForceQuitApplication ||
           (error?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? NSNumber)?.intValue == NSURLErrorCancelledReasonBackgroundUpdatesDisabled {

            guard let downloadTask = task as? URLSessionDownloadTask,
                  let taskDescComponents: [String] = downloadTask.taskDescription?.components(separatedBy: ",") else {

                if let model = self.model(withTask: task),
                   let index = self.index(ofModel: model) {

                    let error: NSError = NSError(
                            domain: "MZDownloadManagerDomain",
                            code: 999,
                            userInfo: [NSLocalizedDescriptionKey : "Unknown error occurred"])

                    self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: model, index: index)
                }

                return
            }

            let fileName = taskDescComponents[self.TaskDescFileNameIndex]
            let fileURL = taskDescComponents[self.TaskDescFileURLIndex]
            let destinationPath = taskDescComponents[self.TaskDescFileDestinationIndex]

            let downloadModel = MZDownloadModel.init(fileName: fileName, fileURL: fileURL, destinationPath: destinationPath)
            downloadModel.status = TaskStatus.failed.description()
            downloadModel.task = downloadTask

            let resumeData = error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

            var newTask = downloadTask
            if let resumeData = resumeData, self.isValidResumeData(resumeData) == true {
                newTask = self.sessionManager.downloadTask(withResumeData: resumeData)
            } else {
                newTask = self.sessionManager.downloadTask(with: self.createRequest(URL(string: fileURL as String)!))
            }

            newTask.taskDescription = downloadTask.taskDescription
            downloadModel.task = newTask
            syncQueue.sync {
                self.downloadingArray.append(downloadModel)
            }
            self.delegate?.downloadRequestDidPopulatedInterruptedTasks(self.downloadingArray)

        } else {

            if let downloadModel = self.model(withTask: task) {
                if error?.code == NSURLErrorCancelled || error == nil {
                    if let index = self.index(ofModel: downloadModel) {
                        syncQueue.sync {
                            self.downloadingArray.remove(at: index)
                        }
                        if error == nil {
                            self.delegate?.downloadRequestFinished?(downloadModel, index: index)
                        } else {
                            self.delegate?.downloadRequestCanceled?(downloadModel, index: index)
                        }
                    }
                } else {
                    var newTask = task
                    if let resumeData = error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                       self.isValidResumeData(resumeData) == true {
                        newTask = self.sessionManager.downloadTask(withResumeData: resumeData)
                    } else {
                        newTask = self.sessionManager.downloadTask(with: self.createRequest(URL(string: downloadModel.fileURL)!))
                    }

                    let oldTask = downloadModel.task

                    newTask.taskDescription = task.taskDescription
                    downloadModel.status = TaskStatus.failed.description()
                    downloadModel.task = newTask as? URLSessionDownloadTask

                    oldTask?.cancel()
                    if let index = self.index(ofModel: downloadModel) {
                        syncQueue.sync {
                            self.downloadingArray[index] = downloadModel
                        }
                        if let error = error {
                            self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: downloadModel, index: index)
                        } else {
                            let error: NSError = NSError(domain: "MZDownloadManagerDomain", code: 1000, userInfo: [NSLocalizedDescriptionKey : "Unknown error occurred"])
                            self.delegate?.downloadRequestDidFailedWithError?(error, downloadModel: downloadModel, index: index)
                        }
                    }
                }
            }
        }

    }
    
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        
        if let backgroundCompletion = self.backgroundSessionCompletionHandler {
            backgroundCompletion()
        }
        debugPrint("All tasks are finished")
        
    }
}

//MARK: Public Helper Functions

extension MZDownloadManager {

    fileprivate func addDownloadTask(_ fileName: String, request: URLRequest, destinationPath: String) {

        let fileURL = request.url?.absoluteString ?? ""
        let downloadTask = sessionManager.downloadTask(with: request)
        downloadTask.taskDescription = [fileName, fileURL, destinationPath].joined(separator: ",")
        downloadTask.resume()

        debugPrint("session manager:\(sessionManager) url:\(fileURL) request:\(request)")

        let downloadModel = MZDownloadModel.init(fileName: fileName, fileURL: fileURL, destinationPath: destinationPath)
        downloadModel.startTime = Date()
        downloadModel.status = TaskStatus.downloading.description()
        downloadModel.task = downloadTask
        syncQueue.sync {
            downloadingArray.append(downloadModel)
        }

        if let index = index(ofModel: downloadModel) {
            delegate?.downloadRequestStarted?(downloadModel, index: index)
        }

    }

    public func addDownloadTask(_ fileName: String, fileURL: URL, destinationPath: String) {
        let request = self.createRequest(fileURL)
        self.addDownloadTask(fileName, request: request, destinationPath: destinationPath)
    }

    public func addDownloadTask(_ fileName: String, fileURL: String, destinationPath: String) {
        guard let url = URL(string: fileURL) else {
            return
        }

        self.addDownloadTask(fileName, fileURL: url, destinationPath: destinationPath)
    }
    
    public func addDownloadTask(_ fileName: String, fileURL: String) {
        addDownloadTask(fileName, fileURL: fileURL, destinationPath: "")
    }
    
    public func pauseDownloadTaskAtIndex(_ index: Int) {
        guard let downloadModel = self.model(atIndex: index),
              downloadModel.status != TaskStatus.paused.description() else {
            return
        }

        let downloadTask = downloadModel.task
        downloadTask?.suspend()
        downloadModel.status = TaskStatus.paused.description()
        downloadModel.startTime = Date()

        if let index = self.index(ofModel: downloadModel) {
            syncQueue.sync {
                downloadingArray[index] = downloadModel
            }
            delegate?.downloadRequestDidPaused?(downloadModel, index: index)
        }

    }
    
    public func resumeDownloadTaskAtIndex(_ index: Int) {
        guard let downloadModel = self.model(atIndex: index),
              downloadModel.status != TaskStatus.downloading.description() else {
            return
        }

        let downloadTask = downloadModel.task
        downloadTask?.resume()
        downloadModel.status = TaskStatus.downloading.description()

        if let index = self.index(ofModel: downloadModel) {
            syncQueue.sync {
                downloadingArray[index] = downloadModel
            }
            delegate?.downloadRequestDidResumed?(downloadModel, index: index)
        }
    }
    
    public func retryDownloadTaskAtIndex(_ index: Int) {
        guard let downloadModel = self.model(atIndex: index),
            downloadModel.status != TaskStatus.downloading.description() else {
            return
        }

        let downloadTask = downloadModel.task

        downloadModel.status = TaskStatus.downloading.description()
        downloadModel.startTime = Date()
        downloadModel.task = downloadTask

        if let index = self.index(ofModel: downloadModel) {
            syncQueue.sync {
                downloadingArray[index] = downloadModel
            }
            downloadTask?.resume()
        }
    }
    
    public func cancelTaskAtIndex(_ index: Int) {
        guard let downloadModel = self.model(atIndex: index) else {
            return
        }

        let downloadTask = downloadModel.task
        downloadTask?.cancel()
    }
    
    public func presentNotificationForDownload(_ notifAction: String, notifBody: String) {
        let application = UIApplication.shared
        let applicationState = application.applicationState
        
        if applicationState == UIApplicationState.background {
            let localNotification = UILocalNotification()
            localNotification.alertBody = notifBody
            localNotification.alertAction = notifAction
            localNotification.soundName = UILocalNotificationDefaultSoundName
            localNotification.applicationIconBadgeNumber += 1
            application.presentLocalNotificationNow(localNotification)
        }
    }
}
