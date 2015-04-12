//
//  AlmManager.swift
//  Alamofire
//
//  Created by Sidharth Juyal on 12/04/15.
//  Copyright (c) 2015 Alamofire. All rights reserved.
//

import Foundation

// MARK: -

/**
Responsible for creating and managing `Request` objects, as well as their underlying `NSURLSession`.

When finished with a manager, be sure to call either `session.finishTasksAndInvalidate()` or `session.invalidateAndCancel()` before deinitialization.
*/
public class Manager {
    
    /**
    A shared instance of `Manager`, used by top-level Alamofire request methods, and suitable for use directly for any ad hoc requests.
    */
    public static let sharedInstance: Manager = {
        let configuration: NSURLSessionConfiguration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.HTTPAdditionalHeaders = Manager.defaultHTTPHeaders
        
        return Manager(configuration: configuration)
        }()
    
    /**
    Creates default values for the "Accept-Encoding", "Accept-Language" and "User-Agent" headers.
    
    :returns: The default header values.
    */
    public static let defaultHTTPHeaders: [String: String] = {
        // Accept-Encoding HTTP Header; see http://tools.ietf.org/html/rfc7230#section-4.2.3
        let acceptEncoding: String = "gzip;q=1.0,compress;q=0.5"
        
        // Accept-Language HTTP Header; see http://tools.ietf.org/html/rfc7231#section-5.3.5
        let acceptLanguage: String = {
            var components: [String] = []
            for (index, languageCode) in enumerate(NSLocale.preferredLanguages() as! [String]) {
                let q = 1.0 - (Double(index) * 0.1)
                components.append("\(languageCode);q=\(q)")
                if q <= 0.5 {
                    break
                }
            }
            
            return join(",", components)
            }()
        
        // User-Agent Header; see http://tools.ietf.org/html/rfc7231#section-5.5.3
        let userAgent: String = {
            if let info = NSBundle.mainBundle().infoDictionary {
                let executable: AnyObject = info[kCFBundleExecutableKey] ?? "Unknown"
                let bundle: AnyObject = info[kCFBundleIdentifierKey] ?? "Unknown"
                let version: AnyObject = info[kCFBundleVersionKey] ?? "Unknown"
                let os: AnyObject = NSProcessInfo.processInfo().operatingSystemVersionString ?? "Unknown"
                
                var mutableUserAgent = NSMutableString(string: "\(executable)/\(bundle) (\(version); OS \(os))") as CFMutableString
                let transform = NSString(string: "Any-Latin; Latin-ASCII; [:^ASCII:] Remove") as CFString
                if CFStringTransform(mutableUserAgent, nil, transform, 0) == 1 {
                    return mutableUserAgent as NSString as! String
                }
            }
            
            return "Alamofire"
            }()
        
        return ["Accept-Encoding": acceptEncoding,
            "Accept-Language": acceptLanguage,
            "User-Agent": userAgent]
        }()
    
    private let queue = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL)
    
    /// The underlying session.
    public let session: NSURLSession
    
    /// The session delegate handling all the task and session delegate callbacks.
    public let delegate: SessionDelegate
    
    /// Whether to start requests immediately after being constructed. `true` by default.
    public var startRequestsImmediately: Bool = true
    
    /// The background completion handler closure provided by the UIApplicationDelegate `application:handleEventsForBackgroundURLSession:completionHandler:` method. By setting the background completion handler, the SessionDelegate `sessionDidFinishEventsForBackgroundURLSession` closure implementation will automatically call the handler. If you need to handle your own events before the handler is called, then you need to override the SessionDelegate `sessionDidFinishEventsForBackgroundURLSession` and manually call the handler when finished. `nil` by default.
    public var backgroundCompletionHandler: (() -> Void)?
    
    /**
    :param: configuration The configuration used to construct the managed session.
    */
    required public init(configuration: NSURLSessionConfiguration? = nil) {
        self.delegate = SessionDelegate()
        self.session = NSURLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        self.delegate.sessionDidFinishEventsForBackgroundURLSession = { [weak self] session in
            if let strongSelf = self {
                strongSelf.backgroundCompletionHandler?()
            }
        }
    }
    
    // MARK: -
    
    /**
    Creates a request for the specified method, URL string, parameters, and parameter encoding.
    
    :param: method The HTTP method.
    :param: URLString The URL string.
    :param: parameters The parameters. `nil` by default.
    :param: encoding The parameter encoding. `.URL` by default.
    
    :returns: The created request.
    */
    public func request(method: Method, _ URLString: URLStringConvertible, parameters: [String: AnyObject]? = nil, encoding: ParameterEncoding = .URL) -> Request {
        return request(encoding.encode(URLRequest(method, URLString), parameters: parameters).0)
    }
    
    
    /**
    Creates a request for the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: URLRequest The URL request
    
    :returns: The created request.
    */
    public func request(URLRequest: URLRequestConvertible) -> Request {
        var dataTask: NSURLSessionDataTask?
        dispatch_sync(queue) {
            dataTask = self.session.dataTaskWithRequest(URLRequest.URLRequest)
        }
        
        let request = Request(session: session, task: dataTask!)
        delegate[request.delegate.task] = request.delegate
        
        if startRequestsImmediately {
            request.resume()
        }
        
        return request
    }
    
    /**
    Responsible for handling all delegate callbacks for the underlying session.
    */
    public final class SessionDelegate: NSObject, NSURLSessionDelegate, NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate {
        private var subdelegates: [Int: Request.TaskDelegate] = [:]
        private let subdelegateQueue = dispatch_queue_create(nil, DISPATCH_QUEUE_CONCURRENT)
        private subscript(task: NSURLSessionTask) -> Request.TaskDelegate? {
            get {
                var subdelegate: Request.TaskDelegate?
                dispatch_sync(subdelegateQueue) {
                    subdelegate = self.subdelegates[task.taskIdentifier]
                }
                
                return subdelegate
            }
            
            set {
                dispatch_barrier_async(subdelegateQueue) {
                    self.subdelegates[task.taskIdentifier] = newValue
                }
            }
        }
        
        // MARK: NSURLSessionDelegate
        
        /// NSURLSessionDelegate override closure for `URLSession:didBecomeInvalidWithError:` method.
        public var sessionDidBecomeInvalidWithError: ((NSURLSession!, NSError!) -> Void)?
        
        /// NSURLSessionDelegate override closure for `URLSession:didReceiveChallenge:completionHandler:` method.
        public var sessionDidReceiveChallenge: ((NSURLSession!, NSURLAuthenticationChallenge) -> (NSURLSessionAuthChallengeDisposition, NSURLCredential!))?
        
        /// NSURLSessionDelegate override closure for `URLSession:didFinishEventsForBackgroundURLSession:` method.
        public var sessionDidFinishEventsForBackgroundURLSession: ((NSURLSession!) -> Void)?
        
        public func URLSession(session: NSURLSession, didBecomeInvalidWithError error: NSError?) {
            sessionDidBecomeInvalidWithError?(session, error)
        }
        
        public func URLSession(session: NSURLSession, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)) {
            if sessionDidReceiveChallenge != nil {
                completionHandler(sessionDidReceiveChallenge!(session, challenge))
            } else {
                completionHandler(.PerformDefaultHandling, nil)
            }
        }
        
        public func URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) {
            sessionDidFinishEventsForBackgroundURLSession?(session)
        }
        
        // MARK: NSURLSessionTaskDelegate
        
        /// Overrides default behavior for NSURLSessionTaskDelegate method `URLSession:willPerformHTTPRedirection:newRequest:completionHandler:`.
        public var taskWillPerformHTTPRedirection: ((NSURLSession!, NSURLSessionTask!, NSHTTPURLResponse!, NSURLRequest!) -> (NSURLRequest!))?
        
        /// Overrides default behavior for NSURLSessionTaskDelegate method `URLSession:willPerformHTTPRedirection:newRequest:completionHandler:`.
        public var taskDidReceiveChallenge: ((NSURLSession!, NSURLSessionTask!, NSURLAuthenticationChallenge) -> (NSURLSessionAuthChallengeDisposition, NSURLCredential!))?
        
        /// Overrides default behavior for NSURLSessionTaskDelegate method `URLSession:task:didCompleteWithError:`.
        public var taskNeedNewBodyStream: ((NSURLSession!, NSURLSessionTask!) -> (NSInputStream!))?
        
        /// Overrides default behavior for NSURLSessionTaskDelegate method `URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:`.
        public var taskDidSendBodyData: ((NSURLSession!, NSURLSessionTask!, Int64, Int64, Int64) -> Void)?
        
        /// Overrides default behavior for NSURLSessionTaskDelegate method `URLSession:task:didCompleteWithError:`.
        public var taskDidComplete: ((NSURLSession!, NSURLSessionTask!, NSError!) -> Void)?
        
        public func URLSession(session: NSURLSession, task: NSURLSessionTask, willPerformHTTPRedirection response: NSHTTPURLResponse, newRequest request: NSURLRequest, completionHandler: ((NSURLRequest!) -> Void)) {
            var redirectRequest = request
            
            if taskWillPerformHTTPRedirection != nil {
                redirectRequest = taskWillPerformHTTPRedirection!(session, task, response, request)
            }
            
            completionHandler(redirectRequest)
        }
        
        public func URLSession(session: NSURLSession, task: NSURLSessionTask, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)) {
            if taskDidReceiveChallenge != nil {
                completionHandler(taskDidReceiveChallenge!(session, task, challenge))
            } else if let delegate = self[task] {
                delegate.URLSession(session, task: task, didReceiveChallenge: challenge, completionHandler: completionHandler)
            } else {
                URLSession(session, didReceiveChallenge: challenge, completionHandler: completionHandler)
            }
        }
        
        public func URLSession(session: NSURLSession, task: NSURLSessionTask, needNewBodyStream completionHandler: ((NSInputStream!) -> Void)) {
            if taskNeedNewBodyStream != nil {
                completionHandler(taskNeedNewBodyStream!(session, task))
            } else if let delegate = self[task] {
                delegate.URLSession(session, task: task, needNewBodyStream: completionHandler)
            }
        }
        
        public func URLSession(session: NSURLSession, task: NSURLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if taskDidSendBodyData != nil {
                taskDidSendBodyData!(session, task, bytesSent, totalBytesSent, totalBytesExpectedToSend)
            } else if let delegate = self[task] as? Request.UploadTaskDelegate {
                delegate.URLSession(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
            }
        }
        
        public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
            if taskDidComplete != nil {
                taskDidComplete!(session, task, error)
            } else if let delegate = self[task] {
                delegate.URLSession(session, task: task, didCompleteWithError: error)
                
                self[task] = nil
            }
        }
        
        // MARK: NSURLSessionDataDelegate
        
        /// Overrides default behavior for NSURLSessionDataDelegate method `URLSession:dataTask:didReceiveResponse:completionHandler:`.
        public var dataTaskDidReceiveResponse: ((NSURLSession!, NSURLSessionDataTask!, NSURLResponse!) -> (NSURLSessionResponseDisposition))?
        
        /// Overrides default behavior for NSURLSessionDataDelegate method `URLSession:dataTask:didBecomeDownloadTask:`.
        public var dataTaskDidBecomeDownloadTask: ((NSURLSession!, NSURLSessionDataTask!, NSURLSessionDownloadTask!) -> Void)?
        
        /// Overrides default behavior for NSURLSessionDataDelegate method `URLSession:dataTask:didReceiveData:`.
        public var dataTaskDidReceiveData: ((NSURLSession!, NSURLSessionDataTask!, NSData!) -> Void)?
        
        /// Overrides default behavior for NSURLSessionDataDelegate method `URLSession:dataTask:willCacheResponse:completionHandler:`.
        public var dataTaskWillCacheResponse: ((NSURLSession!, NSURLSessionDataTask!, NSCachedURLResponse!) -> (NSCachedURLResponse))?
        
        public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: ((NSURLSessionResponseDisposition) -> Void)) {
            var disposition: NSURLSessionResponseDisposition = .Allow
            
            if dataTaskDidReceiveResponse != nil {
                disposition = dataTaskDidReceiveResponse!(session, dataTask, response)
            }
            
            completionHandler(disposition)
        }
        
        public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didBecomeDownloadTask downloadTask: NSURLSessionDownloadTask) {
            if dataTaskDidBecomeDownloadTask != nil {
                dataTaskDidBecomeDownloadTask!(session, dataTask, downloadTask)
            } else {
                let downloadDelegate = Request.DownloadTaskDelegate(task: downloadTask)
                self[downloadTask] = downloadDelegate
            }
        }
        
        public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
            if dataTaskDidReceiveData != nil {
                dataTaskDidReceiveData!(session, dataTask, data)
            } else if let delegate = self[dataTask] as? Request.DataTaskDelegate {
                delegate.URLSession(session, dataTask: dataTask, didReceiveData: data)
            }
        }
        
        public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, willCacheResponse proposedResponse: NSCachedURLResponse, completionHandler: ((NSCachedURLResponse!) -> Void)) {
            if dataTaskWillCacheResponse != nil {
                completionHandler(dataTaskWillCacheResponse!(session, dataTask, proposedResponse))
            } else if let delegate = self[dataTask] as? Request.DataTaskDelegate {
                delegate.URLSession(session, dataTask: dataTask, willCacheResponse: proposedResponse, completionHandler: completionHandler)
            } else {
                completionHandler(proposedResponse)
            }
        }
        
        // MARK: NSURLSessionDownloadDelegate
        
        /// Overrides default behavior for NSURLSessionDownloadDelegate method `URLSession:downloadTask:didFinishDownloadingToURL:`.
        public var downloadTaskDidFinishDownloadingToURL: ((NSURLSession!, NSURLSessionDownloadTask!, NSURL) -> (NSURL))?
        
        /// Overrides default behavior for NSURLSessionDownloadDelegate method `URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:`.
        public var downloadTaskDidWriteData: ((NSURLSession!, NSURLSessionDownloadTask!, Int64, Int64, Int64) -> Void)?
        
        /// Overrides default behavior for NSURLSessionDownloadDelegate method `URLSession:downloadTask:didResumeAtOffset:expectedTotalBytes:`.
        public var downloadTaskDidResumeAtOffset: ((NSURLSession!, NSURLSessionDownloadTask!, Int64, Int64) -> Void)?
        
        public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {
            if downloadTaskDidFinishDownloadingToURL != nil {
                downloadTaskDidFinishDownloadingToURL!(session, downloadTask, location)
            } else if let delegate = self[downloadTask] as? Request.DownloadTaskDelegate {
                delegate.URLSession(session, downloadTask: downloadTask, didFinishDownloadingToURL: location)
            }
        }
        
        public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if downloadTaskDidWriteData != nil {
                downloadTaskDidWriteData!(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
            } else if let delegate = self[downloadTask] as? Request.DownloadTaskDelegate {
                delegate.URLSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
            }
        }
        
        public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
            if downloadTaskDidResumeAtOffset != nil {
                downloadTaskDidResumeAtOffset!(session, downloadTask, fileOffset, expectedTotalBytes)
            } else if let delegate = self[downloadTask] as? Request.DownloadTaskDelegate {
                delegate.URLSession(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
            }
        }
        
        // MARK: NSObject
        
        public override func respondsToSelector(selector: Selector) -> Bool {
            switch selector {
            case "URLSession:didBecomeInvalidWithError:":
                return (sessionDidBecomeInvalidWithError != nil)
            case "URLSession:didReceiveChallenge:completionHandler:":
                return (sessionDidReceiveChallenge != nil)
            case "URLSessionDidFinishEventsForBackgroundURLSession:":
                return (sessionDidFinishEventsForBackgroundURLSession != nil)
            case "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:":
                return (taskWillPerformHTTPRedirection != nil)
            case "URLSession:dataTask:didReceiveResponse:completionHandler:":
                return (dataTaskDidReceiveResponse != nil)
            case "URLSession:dataTask:willCacheResponse:completionHandler:":
                return (dataTaskWillCacheResponse != nil)
            default:
                return self.dynamicType.instancesRespondToSelector(selector)
            }
        }
    }
}

// MARK: - Upload

extension Manager {
    private enum Uploadable {
        case Data(NSURLRequest, NSData)
        case File(NSURLRequest, NSURL)
        case Stream(NSURLRequest, NSInputStream)
    }
    
    private func upload(uploadable: Uploadable) -> Request {
        var uploadTask: NSURLSessionUploadTask!
        var HTTPBodyStream: NSInputStream?
        
        switch uploadable {
        case .Data(let request, let data):
            uploadTask = session.uploadTaskWithRequest(request, fromData: data)
        case .File(let request, let fileURL):
            uploadTask = session.uploadTaskWithRequest(request, fromFile: fileURL)
        case .Stream(let request, var stream):
            uploadTask = session.uploadTaskWithStreamedRequest(request)
            HTTPBodyStream = stream
        }
        
        let request = Request(session: session, task: uploadTask)
        if HTTPBodyStream != nil {
            request.delegate.taskNeedNewBodyStream = { _, _ in
                return HTTPBodyStream
            }
        }
        delegate[request.delegate.task] = request.delegate
        
        if startRequestsImmediately {
            request.resume()
        }
        
        return request
    }
    
    // MARK: File
    
    /**
    Creates a request for uploading a file to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: URLRequest The URL request
    :param: file The file to upload
    
    :returns: The created upload request.
    */
    public func upload(URLRequest: URLRequestConvertible, file: NSURL) -> Request {
        return upload(.File(URLRequest.URLRequest, file))
    }
    
    /**
    Creates a request for uploading a file to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: method The HTTP method.
    :param: URLString The URL string.
    :param: file The file to upload
    
    :returns: The created upload request.
    */
    public func upload(method: Method, _ URLString: URLStringConvertible, file: NSURL) -> Request {
        return upload(URLRequest(method, URLString), file: file)
    }
    
    // MARK: Data
    
    /**
    Creates a request for uploading data to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: URLRequest The URL request
    :param: data The data to upload
    
    :returns: The created upload request.
    */
    public func upload(URLRequest: URLRequestConvertible, data: NSData) -> Request {
        return upload(.Data(URLRequest.URLRequest, data))
    }
    
    /**
    Creates a request for uploading data to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: method The HTTP method.
    :param: URLString The URL string.
    :param: data The data to upload
    
    :returns: The created upload request.
    */
    public func upload(method: Method, _ URLString: URLStringConvertible, data: NSData) -> Request {
        return upload(URLRequest(method, URLString), data: data)
    }
    
    // MARK: Stream
    
    /**
    Creates a request for uploading a stream to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: URLRequest The URL request
    :param: stream The stream to upload
    
    :returns: The created upload request.
    */
    public func upload(URLRequest: URLRequestConvertible, stream: NSInputStream) -> Request {
        return upload(.Stream(URLRequest.URLRequest, stream))
    }
    
    /**
    Creates a request for uploading a stream to the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: method The HTTP method.
    :param: URLString The URL string.
    :param: stream The stream to upload.
    
    :returns: The created upload request.
    */
    public func upload(method: Method, _ URLString: URLStringConvertible, stream: NSInputStream) -> Request {
        return upload(URLRequest(method, URLString), stream: stream)
    }
}

// MARK: - Download

extension Manager {
    private enum Downloadable {
        case Request(NSURLRequest)
        case ResumeData(NSData)
    }
    
    private func download(downloadable: Downloadable, destination: Request.DownloadFileDestination) -> Request {
        var downloadTask: NSURLSessionDownloadTask!
        
        switch downloadable {
        case .Request(let request):
            downloadTask = session.downloadTaskWithRequest(request)
        case .ResumeData(let resumeData):
            downloadTask = session.downloadTaskWithResumeData(resumeData)
        }
        
        let request = Request(session: session, task: downloadTask)
        if let downloadDelegate = request.delegate as? Request.DownloadTaskDelegate {
            downloadDelegate.downloadTaskDidFinishDownloadingToURL = { (session, downloadTask, URL) in
                return destination(URL, downloadTask.response as! NSHTTPURLResponse)
            }
        }
        delegate[request.delegate.task] = request.delegate
        
        if startRequestsImmediately {
            request.resume()
        }
        
        return request
    }
    
    // MARK: Request
    
    /**
    Creates a download request using the shared manager instance for the specified method and URL string.
    
    :param: method The HTTP method.
    :param: URLString The URL string.
    :param: destination The closure used to determine the destination of the downloaded file.
    
    :returns: The created download request.
    */
    public func download(method: Method, _ URLString: URLStringConvertible, destination: Request.DownloadFileDestination) -> Request {
        return download(URLRequest(method, URLString), destination: destination)
    }
    
    /**
    Creates a request for downloading from the specified URL request.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: URLRequest The URL request
    :param: destination The closure used to determine the destination of the downloaded file.
    
    :returns: The created download request.
    */
    public func download(URLRequest: URLRequestConvertible, destination: Request.DownloadFileDestination) -> Request {
        return download(.Request(URLRequest.URLRequest), destination: destination)
    }
    
    // MARK: Resume Data
    
    /**
    Creates a request for downloading from the resume data produced from a previous request cancellation.
    
    If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    
    :param: resumeData The resume data. This is an opaque data blob produced by `NSURLSessionDownloadTask` when a task is cancelled. See `NSURLSession -downloadTaskWithResumeData:` for additional information.
    :param: destination The closure used to determine the destination of the downloaded file.
    
    :returns: The created download request.
    */
    public func download(resumeData: NSData, destination: Request.DownloadFileDestination) -> Request {
        return download(.ResumeData(resumeData), destination: destination)
    }
}
