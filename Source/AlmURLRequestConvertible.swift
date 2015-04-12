//
//  AlmURLRequestConvertible.swift
//  Alamofire
//
//  Created by Sidharth Juyal on 12/04/15.
//  Copyright (c) 2015 Alamofire. All rights reserved.
//

import Foundation

// MARK: - URLRequestConvertible

/**
Types adopting the `URLRequestConvertible` protocol can be used to construct URL requests.
*/
public protocol URLRequestConvertible {
    /// The URL request.
    var URLRequest: NSURLRequest { get }
}

extension NSURLRequest: URLRequestConvertible {
    public var URLRequest: NSURLRequest {
        return self
    }
}
