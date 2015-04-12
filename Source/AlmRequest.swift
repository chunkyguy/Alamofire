//
//  AlmRequest.swift
//  Alamofire
//
//  Created by Sidharth Juyal on 12/04/15.
//  Copyright (c) 2015 Alamofire. All rights reserved.
//

import Foundation

// MARK: -

/**
Responsible for sending a request and receiving the response and associated data from the server, as well as managing its underlying `NSURLSessionTask`.
*/
public class Request {
    internal let delegate: TaskDelegate
    
    /// The underlying task.
    public var task: NSURLSessionTask { return delegate.task }
    
    /// The session belonging to the underlying task.
    public let session: NSURLSession
    
    /// The request sent or to be sent to the server.
    public var request: NSURLRequest { return task.originalRequest }
    
    /// The response received from the server, if any.
    public var response: NSHTTPURLResponse? { return task.response as? NSHTTPURLResponse }
    
    /// The progress of the request lifecycle.
    public var progress: NSProgress { return delegate.progress }
    
    internal init(session: NSURLSession, task: NSURLSessionTask) {
        self.session = session
        
        switch task {
        case is NSURLSessionUploadTask:
            self.delegate = UploadTaskDelegate(task: task)
        case is NSURLSessionDataTask:
            self.delegate = DataTaskDelegate(task: task)
        case is NSURLSessionDownloadTask:
            self.delegate = DownloadTaskDelegate(task: task)
        default:
            self.delegate = TaskDelegate(task: task)
        }
    }
    
    // MARK: Authentication
    
    /**
    Associates an HTTP Basic credential with the request.
    
    :param: user The user.
    :param: password The password.
    
    :returns: The request.
    */
    public func authenticate(#user: String, password: String) -> Self {
        let credential = NSURLCredential(user: user, password: password, persistence: .ForSession)
        
        return authenticate(usingCredential: credential)
    }
    
    /**
    Associates a specified credential with the request.
    
    :param: credential The credential.
    
    :returns: The request.
    */
    public func authenticate(usingCredential credential: NSURLCredential) -> Self {
        delegate.credential = credential
        
        return self
    }
    
    // MARK: Progress
    
    /**
    Sets a closure to be called periodically during the lifecycle of the request as data is written to or read from the server.
    
    - For uploads, the progress closure returns the bytes written, total bytes written, and total bytes expected to write.
    - For downloads, the progress closure returns the bytes read, total bytes read, and total bytes expected to write.
    
    :param: closure The code to be executed periodically during the lifecycle of the request.
    
    :returns: The request.
    */
    public func progress(closure: ((Int64, Int64, Int64) -> Void)? = nil) -> Self {
        if let uploadDelegate = delegate as? UploadTaskDelegate {
            uploadDelegate.uploadProgress = closure
        } else if let dataDelegate = delegate as? DataTaskDelegate {
            dataDelegate.dataProgress = closure
        } else if let downloadDelegate = delegate as? DownloadTaskDelegate {
            downloadDelegate.downloadProgress = closure
        }
        
        return self
    }
    
    // MARK: Response
    
    /**
    A closure used by response handlers that takes a request, response, and data and returns a serialized object and any error that occured in the process.
    */
    public typealias Serializer = (NSURLRequest, NSHTTPURLResponse?, NSData?) -> (AnyObject?, NSError?)
    
    /**
    Creates a response serializer that returns the associated data as-is.
    
    :returns: A data response serializer.
    */
    public class func responseDataSerializer() -> Serializer {
        return { (request, response, data) in
            return (data, nil)
        }
    }
    
    /**
    Adds a handler to be called once the request has finished.
    
    :param: completionHandler The code to be executed once the request has finished.
    
    :returns: The request.
    */
    public func response(completionHandler: (NSURLRequest, NSHTTPURLResponse?, AnyObject?, NSError?) -> Void) -> Self {
        return response(serializer: Request.responseDataSerializer(), completionHandler: completionHandler)
    }
    
    /**
    Adds a handler to be called once the request has finished.
    
    :param: queue The queue on which the completion handler is dispatched.
    :param: serializer The closure responsible for serializing the request, response, and data.
    :param: completionHandler The code to be executed once the request has finished.
    
    :returns: The request.
    */
    public func response(queue: dispatch_queue_t? = nil, serializer: Serializer, completionHandler: (NSURLRequest, NSHTTPURLResponse?, AnyObject?, NSError?) -> Void) -> Self {
        dispatch_async(delegate.queue) {
            let (responseObject: AnyObject?, serializationError: NSError?) = serializer(self.request, self.response, self.delegate.data)
            
            dispatch_async(queue ?? dispatch_get_main_queue()) {
                completionHandler(self.request, self.response, responseObject, self.delegate.error ?? serializationError)
            }
        }
        
        return self
    }
    
    /**
    Suspends the request.
    */
    public func suspend() {
        task.suspend()
    }
    
    /**
    Resumes the request.
    */
    public func resume() {
        task.resume()
    }
    
    /**
    Cancels the request.
    */
    public func cancel() {
        if let downloadDelegate = delegate as? DownloadTaskDelegate {
            downloadDelegate.downloadTask.cancelByProducingResumeData { (data) in
                downloadDelegate.resumeData = data
            }
        } else {
            task.cancel()
        }
    }
    
    class TaskDelegate: NSObject, NSURLSessionTaskDelegate {
        let task: NSURLSessionTask
        let queue: dispatch_queue_t
        let progress: NSProgress
        
        var data: NSData? { return nil }
        private(set) var error: NSError?
        
        var credential: NSURLCredential?
        
        var taskWillPerformHTTPRedirection: ((NSURLSession!, NSURLSessionTask!, NSHTTPURLResponse!, NSURLRequest!) -> (NSURLRequest!))?
        var taskDidReceiveChallenge: ((NSURLSession!, NSURLSessionTask!, NSURLAuthenticationChallenge) -> (NSURLSessionAuthChallengeDisposition, NSURLCredential?))?
        var taskDidSendBodyData: ((NSURLSession!, NSURLSessionTask!, Int64, Int64, Int64) -> Void)?
        var taskNeedNewBodyStream: ((NSURLSession!, NSURLSessionTask!) -> (NSInputStream!))?
        
        init(task: NSURLSessionTask) {
            self.task = task
            self.progress = NSProgress(totalUnitCount: 0)
            self.queue = {
                let label: String = "com.alamofire.task-\(task.taskIdentifier)"
                let queue = dispatch_queue_create((label as NSString).UTF8String, DISPATCH_QUEUE_SERIAL)
                
                dispatch_suspend(queue)
                
                return queue
                }()
        }
        
        // MARK: NSURLSessionTaskDelegate
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, willPerformHTTPRedirection response: NSHTTPURLResponse, newRequest request: NSURLRequest, completionHandler: ((NSURLRequest!) -> Void)) {
            var redirectRequest = request
            if taskWillPerformHTTPRedirection != nil {
                redirectRequest = taskWillPerformHTTPRedirection!(session, task, response, request)
            }
            
            completionHandler(redirectRequest)
        }
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)) {
            var disposition: NSURLSessionAuthChallengeDisposition = .PerformDefaultHandling
            var credential: NSURLCredential?
            
            if taskDidReceiveChallenge != nil {
                (disposition, credential) = taskDidReceiveChallenge!(session, task, challenge)
            } else {
                if challenge.previousFailureCount > 0 {
                    disposition = .CancelAuthenticationChallenge
                } else {
                    // TODO: Incorporate Trust Evaluation & TLS Chain Validation
                    
                    switch challenge.protectionSpace.authenticationMethod! {
                    case NSURLAuthenticationMethodServerTrust:
                        credential = NSURLCredential(forTrust: challenge.protectionSpace.serverTrust)
                    default:
                        credential = self.credential ?? session.configuration.URLCredentialStorage?.defaultCredentialForProtectionSpace(challenge.protectionSpace)
                    }
                    
                    if credential != nil {
                        disposition = .UseCredential
                    }
                }
            }
            
            completionHandler(disposition, credential)
        }
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, needNewBodyStream completionHandler: ((NSInputStream!) -> Void)) {
            var bodyStream: NSInputStream?
            if taskNeedNewBodyStream != nil {
                bodyStream = taskNeedNewBodyStream!(session, task)
            }
            
            completionHandler(bodyStream)
        }
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
            if error != nil {
                self.error = error
            }
            
            dispatch_resume(queue)
        }
    }
    
    class DataTaskDelegate: TaskDelegate, NSURLSessionDataDelegate {
        var dataTask: NSURLSessionDataTask! { return task as! NSURLSessionDataTask }
        
        private var mutableData: NSMutableData
        override var data: NSData? {
            return mutableData
        }
        
        private var expectedContentLength: Int64?
        
        var dataTaskDidReceiveResponse: ((NSURLSession!, NSURLSessionDataTask!, NSURLResponse!) -> (NSURLSessionResponseDisposition))?
        var dataTaskDidBecomeDownloadTask: ((NSURLSession!, NSURLSessionDataTask!) -> Void)?
        var dataTaskDidReceiveData: ((NSURLSession!, NSURLSessionDataTask!, NSData!) -> Void)?
        var dataTaskWillCacheResponse: ((NSURLSession!, NSURLSessionDataTask!, NSCachedURLResponse!) -> (NSCachedURLResponse))?
        var dataProgress: ((bytesReceived: Int64, totalBytesReceived: Int64, totalBytesExpectedToReceive: Int64) -> Void)?
        
        override init(task: NSURLSessionTask) {
            self.mutableData = NSMutableData()
            super.init(task: task)
        }
        
        // MARK: NSURLSessionDataDelegate
        
        func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: ((NSURLSessionResponseDisposition) -> Void)) {
            var disposition: NSURLSessionResponseDisposition = .Allow
            
            expectedContentLength = response.expectedContentLength
            
            if dataTaskDidReceiveResponse != nil {
                disposition = dataTaskDidReceiveResponse!(session, dataTask, response)
            }
            
            completionHandler(disposition)
        }
        
        func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didBecomeDownloadTask downloadTask: NSURLSessionDownloadTask) {
            dataTaskDidBecomeDownloadTask?(session, dataTask)
        }
        
        func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
            dataTaskDidReceiveData?(session, dataTask, data)
            
            mutableData.appendData(data)
            
            if let expectedContentLength = dataTask.response?.expectedContentLength {
                dataProgress?(bytesReceived: Int64(data.length), totalBytesReceived: Int64(mutableData.length), totalBytesExpectedToReceive: expectedContentLength)
            }
        }
        
        func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, willCacheResponse proposedResponse: NSCachedURLResponse, completionHandler: ((NSCachedURLResponse!) -> Void)) {
            var cachedResponse = proposedResponse
            
            if dataTaskWillCacheResponse != nil {
                cachedResponse = dataTaskWillCacheResponse!(session, dataTask, proposedResponse)
            }
            
            completionHandler(cachedResponse)
        }
    }
}

// MARK: - Validation

extension Request {
    
    /**
    A closure used to validate a request that takes a URL request and URL response, and returns whether the request was valid.
    */
    public typealias Validation = (NSURLRequest, NSHTTPURLResponse) -> (Bool)
    
    /**
    Validates the request, using the specified closure.
    
    If validation fails, subsequent calls to response handlers will have an associated error.
    
    :param: validation A closure to validate the request.
    
    :returns: The request.
    */
    public func validate(validation: Validation) -> Self {
        dispatch_async(delegate.queue) {
            if self.response != nil && self.delegate.error == nil {
                if !validation(self.request, self.response!) {
                    self.delegate.error = NSError(domain: AlamofireErrorDomain, code: -1, userInfo: nil)
                }
            }
        }
        
        return self
    }
    
    // MARK: Status Code
    
    /**
    Validates that the response has a status code in the specified range.
    
    If validation fails, subsequent calls to response handlers will have an associated error.
    
    :param: range The range of acceptable status codes.
    
    :returns: The request.
    */
    public func validate<S : SequenceType where S.Generator.Element == Int>(statusCode acceptableStatusCode: S) -> Self {
        return validate { (_, response) in
            return contains(acceptableStatusCode, response.statusCode)
        }
    }
    
    // MARK: Content-Type
    
    private struct MIMEType {
        let type: String
        let subtype: String
        
        init?(_ string: String) {
            let components = string.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet()).substringToIndex(string.rangeOfString(";")?.endIndex ?? string.endIndex).componentsSeparatedByString("/")
            
            if let type = components.first,
                subtype = components.last
            {
                self.type = type
                self.subtype = subtype
            } else {
                return nil
            }
        }
        
        func matches(MIME: MIMEType) -> Bool {
            switch (type, subtype) {
            case (MIME.type, MIME.subtype), (MIME.type, "*"), ("*", MIME.subtype), ("*", "*"):
                return true
            default:
                return false
            }
        }
    }
    
    /**
    Validates that the response has a content type in the specified array.
    
    If validation fails, subsequent calls to response handlers will have an associated error.
    
    :param: contentType The acceptable content types, which may specify wildcard types and/or subtypes.
    
    :returns: The request.
    */
    public func validate<S : SequenceType where S.Generator.Element == String>(contentType acceptableContentTypes: S) -> Self {
        return validate {(_, response) in
            if let responseContentType = response.MIMEType,
                responseMIMEType = MIMEType(responseContentType)
            {
                for contentType in acceptableContentTypes {
                    if let acceptableMIMEType = MIMEType(contentType)
                        where acceptableMIMEType.matches(responseMIMEType)
                    {
                        return true
                    }
                }
            }
            
            return false
        }
    }
    
    // MARK: Automatic
    
    /**
    Validates that the response has a status code in the default acceptable range of 200...299, and that the content type matches any specified in the Accept HTTP header field.
    
    If validation fails, subsequent calls to response handlers will have an associated error.
    
    :returns: The request.
    */
    public func validate() -> Self {
        let acceptableStatusCodes: Range<Int> = 200..<300
        let acceptableContentTypes: [String] = {
            if let accept = self.request.valueForHTTPHeaderField("Accept") {
                return accept.componentsSeparatedByString(",")
            }
            
            return ["*/*"]
            }()
        
        return validate(statusCode: acceptableStatusCodes).validate(contentType: acceptableContentTypes)
    }
}

extension Request {
    class UploadTaskDelegate: DataTaskDelegate {
        var uploadTask: NSURLSessionUploadTask! { return task as! NSURLSessionUploadTask }
        var uploadProgress: ((Int64, Int64, Int64) -> Void)!
        
        // MARK: NSURLSessionTaskDelegate
        
        func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress.totalUnitCount = totalBytesExpectedToSend
            progress.completedUnitCount = totalBytesSent
            
            uploadProgress?(bytesSent, totalBytesSent, totalBytesExpectedToSend)
        }
    }
}

extension Request {
    /**
    A closure executed once a request has successfully completed in order to determine where to move the temporary file written to during the download process. The closure takes two arguments: the temporary file URL and the URL response, and returns a single argument: the file URL where the temporary file should be moved.
    */
    public typealias DownloadFileDestination = (NSURL, NSHTTPURLResponse) -> (NSURL)
    
    /**
    Creates a download file destination closure which uses the default file manager to move the temporary file to a file URL in the first available directory with the specified search path directory and search path domain mask.
    
    :param: directory The search path directory. `.DocumentDirectory` by default.
    :param: domain The search path domain mask. `.UserDomainMask` by default.
    
    :returns: A download file destination closure.
    */
    public class func suggestedDownloadDestination(directory: NSSearchPathDirectory = .DocumentDirectory, domain: NSSearchPathDomainMask = .UserDomainMask) -> DownloadFileDestination {
        
        return { (temporaryURL, response) -> (NSURL) in
            if let directoryURL = NSFileManager.defaultManager().URLsForDirectory(directory, inDomains: domain)[0] as? NSURL {
                return directoryURL.URLByAppendingPathComponent(response.suggestedFilename!)
            }
            
            return temporaryURL
        }
    }
    
    class DownloadTaskDelegate: TaskDelegate, NSURLSessionDownloadDelegate {
        var downloadTask: NSURLSessionDownloadTask! { return task as! NSURLSessionDownloadTask }
        var downloadProgress: ((Int64, Int64, Int64) -> Void)?
        
        var resumeData: NSData?
        override var data: NSData? { return resumeData }
        
        var downloadTaskDidFinishDownloadingToURL: ((NSURLSession!, NSURLSessionDownloadTask!, NSURL) -> (NSURL))?
        var downloadTaskDidWriteData: ((NSURLSession!, NSURLSessionDownloadTask!, Int64, Int64, Int64) -> Void)?
        var downloadTaskDidResumeAtOffset: ((NSURLSession!, NSURLSessionDownloadTask!, Int64, Int64) -> Void)?
        
        // MARK: NSURLSessionDownloadDelegate
        
        func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {
            if downloadTaskDidFinishDownloadingToURL != nil {
                let destination = downloadTaskDidFinishDownloadingToURL!(session, downloadTask, location)
                var fileManagerError: NSError?
                
                NSFileManager.defaultManager().moveItemAtURL(location, toURL: destination, error: &fileManagerError)
                if fileManagerError != nil {
                    error = fileManagerError
                }
            }
        }
        
        func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress.totalUnitCount = totalBytesExpectedToWrite
            progress.completedUnitCount = totalBytesWritten
            
            downloadTaskDidWriteData?(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
            
            downloadProgress?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
        }
        
        func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
            progress.totalUnitCount = expectedTotalBytes
            progress.completedUnitCount = fileOffset
            
            downloadTaskDidResumeAtOffset?(session, downloadTask, fileOffset, expectedTotalBytes)
        }
    }
}

// MARK: - Printable

extension Request: Printable {
    /// The textual representation used when written to an `OutputStreamType`, which includes the HTTP method and URL, as well as the response status code if a response has been received.
    public var description: String {
        var components: [String] = []
        if request.HTTPMethod != nil {
            components.append(request.HTTPMethod!)
        }
        
        components.append(request.URL!.absoluteString!)
        
        if response != nil {
            components.append("(\(response!.statusCode))")
        }
        
        return join(" ", components)
    }
}

extension Request: DebugPrintable {
    func cURLRepresentation() -> String {
        var components: [String] = ["$ curl -i"]
        
        let URL = request.URL
        
        if request.HTTPMethod != nil && request.HTTPMethod != "GET" {
            components.append("-X \(request.HTTPMethod!)")
        }
        
        if let credentialStorage = self.session.configuration.URLCredentialStorage {
            let protectionSpace = NSURLProtectionSpace(host: URL!.host!, port: URL!.port?.integerValue ?? 0, `protocol`: URL!.scheme!, realm: URL!.host!, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            if let credentials = credentialStorage.credentialsForProtectionSpace(protectionSpace)?.values.array {
                for credential: NSURLCredential in (credentials as! [NSURLCredential]) {
                    components.append("-u \(credential.user!):\(credential.password!)")
                }
            } else {
                if let credential = delegate.credential {
                    components.append("-u \(credential.user!):\(credential.password!)")
                }
            }
        }
        
        // Temporarily disabled on OS X due to build failure for CocoaPods
        // See https://github.com/CocoaPods/swift/issues/24
        #if !os(OSX)
            if let cookieStorage = session.configuration.HTTPCookieStorage,
                cookies = cookieStorage.cookiesForURL(URL!) as? [NSHTTPCookie]
                where !cookies.isEmpty
            {
                let string = cookies.reduce(""){ $0 + "\($1.name)=\($1.value ?? String());" }
                components.append("-b \"\(string.substringToIndex(string.endIndex.predecessor()))\"")
            }
        #endif
        
        if request.allHTTPHeaderFields != nil {
            for (field, value) in request.allHTTPHeaderFields! {
                switch field {
                case "Cookie":
                    continue
                default:
                    components.append("-H \"\(field): \(value)\"")
                }
            }
        }
        
        if session.configuration.HTTPAdditionalHeaders != nil {
            for (field, value) in session.configuration.HTTPAdditionalHeaders! {
                switch field {
                case "Cookie":
                    continue
                default:
                    components.append("-H \"\(field): \(value)\"")
                }
            }
        }
        
        if let HTTPBody = request.HTTPBody,
            escapedBody = NSString(data: HTTPBody, encoding: NSUTF8StringEncoding)?.stringByReplacingOccurrencesOfString("\"", withString: "\\\"")
        {
            components.append("-d \"\(escapedBody)\"")
        }
        
        components.append("\"\(URL!.absoluteString!)\"")
        
        return join(" \\\n\t", components)
    }
    
    /// The textual representation used when written to an `OutputStreamType`, in the form of a cURL command.
    public var debugDescription: String {
        return cURLRepresentation()
    }
}

// MARK: - Response Serializers

// MARK: String

extension Request {
    /**
    Creates a response serializer that returns a string initialized from the response data with the specified string encoding.
    
    :param: encoding The string encoding. If `nil`, the string encoding will be determined from the server response, falling back to the default HTTP default character set, ISO-8859-1.
    
    :returns: A string response serializer.
    */
    public class func stringResponseSerializer(var encoding: NSStringEncoding? = nil) -> Serializer {
        return { (_, response, data) in
            if data == nil || data?.length == 0 {
                return (nil, nil)
            }
            
            if encoding == nil {
                if let encodingName = response?.textEncodingName {
                    encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(encodingName))
                }
            }
            
            let string = NSString(data: data!, encoding: encoding ?? NSISOLatin1StringEncoding)
            
            return (string, nil)
        }
    }
    
    /**
    Adds a handler to be called once the request has finished.
    
    :param: encoding The string encoding. If `nil`, the string encoding will be determined from the server response, falling back to the default HTTP default character set, ISO-8859-1.
    :param: completionHandler A closure to be executed once the request has finished. The closure takes 4 arguments: the URL request, the URL response, if one was received, the string, if one could be created from the URL response and data, and any error produced while creating the string.
    
    :returns: The request.
    */
    public func responseString(encoding: NSStringEncoding? = nil, completionHandler: (NSURLRequest, NSHTTPURLResponse?, String?, NSError?) -> Void) -> Self  {
        return response(serializer: Request.stringResponseSerializer(encoding: encoding), completionHandler: { request, response, string, error in
            completionHandler(request, response, string as? String, error)
        })
    }
}

// MARK: JSON

extension Request {
    /**
    Creates a response serializer that returns a JSON object constructed from the response data using `NSJSONSerialization` with the specified reading options.
    
    :param: options The JSON serialization reading options. `.AllowFragments` by default.
    
    :returns: A JSON object response serializer.
    */
    public class func JSONResponseSerializer(options: NSJSONReadingOptions = .AllowFragments) -> Serializer {
        return { (request, response, data) in
            if data == nil || data?.length == 0 {
                return (nil, nil)
            }
            
            var serializationError: NSError?
            let JSON: AnyObject? = NSJSONSerialization.JSONObjectWithData(data!, options: options, error: &serializationError)
            
            return (JSON, serializationError)
        }
    }
    
    /**
    Adds a handler to be called once the request has finished.
    
    :param: options The JSON serialization reading options. `.AllowFragments` by default.
    :param: completionHandler A closure to be executed once the request has finished. The closure takes 4 arguments: the URL request, the URL response, if one was received, the JSON object, if one could be created from the URL response and data, and any error produced while creating the JSON object.
    
    :returns: The request.
    */
    public func responseJSON(options: NSJSONReadingOptions = .AllowFragments, completionHandler: (NSURLRequest, NSHTTPURLResponse?, AnyObject?, NSError?) -> Void) -> Self {
        return response(serializer: Request.JSONResponseSerializer(options: options), completionHandler: { (request, response, JSON, error) in
            completionHandler(request, response, JSON, error)
        })
    }
}

// MARK: Property List

extension Request {
    /**
    Creates a response serializer that returns an object constructed from the response data using `NSPropertyListSerialization` with the specified reading options.
    
    :param: options The property list reading options. `0` by default.
    
    :returns: A property list object response serializer.
    */
    public class func propertyListResponseSerializer(options: NSPropertyListReadOptions = 0) -> Serializer {
        return { (request, response, data) in
            if data == nil || data?.length == 0 {
                return (nil, nil)
            }
            
            var propertyListSerializationError: NSError?
            let plist: AnyObject? = NSPropertyListSerialization.propertyListWithData(data!, options: options, format: nil, error: &propertyListSerializationError)
            
            return (plist, propertyListSerializationError)
        }
    }
    
    /**
    Adds a handler to be called once the request has finished.
    
    :param: options The property list reading options. `0` by default.
    :param: completionHandler A closure to be executed once the request has finished. The closure takes 4 arguments: the URL request, the URL response, if one was received, the property list, if one could be created from the URL response and data, and any error produced while creating the property list.
    
    :returns: The request.
    */
    public func responsePropertyList(options: NSPropertyListReadOptions = 0, completionHandler: (NSURLRequest, NSHTTPURLResponse?, AnyObject?, NSError?) -> Void) -> Self {
        return response(serializer: Request.propertyListResponseSerializer(options: options), completionHandler: { (request, response, plist, error) in
            completionHandler(request, response, plist, error)
        })
    }
}

