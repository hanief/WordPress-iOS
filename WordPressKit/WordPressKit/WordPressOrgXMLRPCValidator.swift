import Foundation
import CocoaLumberjack

@objc public enum WordPressOrgXMLRPCValidatorError: Int, Error {
    case emptyURL // The URL provided was nil, empty or just whitespaces
    case invalidURL // The URL provided was an invalid URL
    case invalidScheme // The URL provided was an invalid scheme, only HTTP and HTTPS supported
    case notWordPressError // That's a XML-RPC endpoint but doesn't look like WordPress
    case mobilePluginRedirectedError // There's some "mobile" plugin redirecting everything to their site
    case invalid // Doesn't look to be valid XMLRPC Endpoint.

    func convertToNSError() -> NSError {
        let castedError = self as NSError
        let message: String
        switch (self) {
        case .emptyURL:
            message = NSLocalizedString("Empty URL", comment: "Message to show to user when he tries to add a self-hosted site that is an empty URL.")
        case .invalidURL:
            message = NSLocalizedString("Invalid URL, please check if you wrote a valid site address.", comment: "Message to show to user when he tries to add a self-hosted site that isn't a valid URL.")
        case .invalidScheme:
            message = NSLocalizedString("Invalid URL scheme inserted, only HTTP and HTTPS are supported.", comment: "Message to show to user when he tries to add a self-hosted site that isn't HTTP or HTTPS.")
        case .notWordPressError:
            message = NSLocalizedString("That doesn't look like a WordPress site.", comment: "Message to show to user when he tries to add a self-hosted site that isn't a WordPress site.")
        case .mobilePluginRedirectedError:
            message = NSLocalizedString("You seem to have installed a mobile plugin from DudaMobile which is preventing the app to connect to your blog", comment: "")
        case .invalid:
            message = NSLocalizedString("That doesn't look like a WordPress site.", comment: "Message to show to user when he tries to add a self-hosted site that isn't a WordPress site.")
        }
        let finalError = NSError(domain: castedError.domain,
                                 code: castedError.code,
                                 userInfo: [NSLocalizedDescriptionKey: message])
        return finalError
    }
}

/// An WordPressOrgXMLRPCValidator is able to validate and check if user provided site urls are
/// WordPress XMLRPC sites.
open class WordPressOrgXMLRPCValidator: NSObject {

    open static let UserInfoHasJetpackKey = "UserInfoHasJetpackKey"

    // The documentation for NSURLErrorHTTPTooManyRedirects says that 16
    // is the default threshold for allowable redirects.
    private let redirectLimit = 16

    override public init() {
        super.init()
    }

    /**
     Validates and check if user provided site urls are WordPress XMLRPC sites and returns the API endpoint.

     - parameter site:      the user provided site URL
     - parameter userAgent: user agent for anonymous .com API to check if a site is a Jetpack site
     - parameter success:   completion handler that is invoked when the site is considered valid,
     the xmlrpcURL argument is the endpoint
     - parameter failure: completion handler that is invoked when the site is considered invalid,
     the error object provides details why the endpoint is invalid
     */
    open func guessXMLRPCURLForSite(_ site: String,
                                    userAgent: String,
                                      success: @escaping (_ xmlrpcURL: URL) -> (),
                                      failure: @escaping (_ error: NSError) -> ()) {
        let originalXMLRPCURL: URL
        let xmlrpcURL: URL
        do {
            xmlrpcURL = try urlForXMLRPCFromURLString(site, addXMLRPC: true)
            originalXMLRPCURL = try urlForXMLRPCFromURLString(site, addXMLRPC: false)
        } catch let error as NSError {
            DDLogError(error.localizedDescription)
            failure(error)
            return
        }

        validateXMLRPCURL(xmlrpcURL, success: success, failure: { (error) in
                DDLogError(error.localizedDescription)
                if (error.domain == NSURLErrorDomain && error.code == NSURLErrorUserCancelledAuthentication) ||
                    (error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotFindHost) ||
                    (error.domain == NSURLErrorDomain && error.code == NSURLErrorNetworkConnectionLost) ||
                    (error.domain == String(reflecting: WordPressOrgXMLRPCValidatorError.self) && error.code == WordPressOrgXMLRPCValidatorError.mobilePluginRedirectedError.rawValue) {
                    failure(error)
                    return
                }
                // Try the original given url as an XML-RPC endpoint
                DDLogError("Try the original given url as an XML-RPC endpoint: \(originalXMLRPCURL)")
                self.validateXMLRPCURL(originalXMLRPCURL , success: success, failure: { (error) in
                    DDLogError(error.localizedDescription)
                    // Fetch the original url and look for the RSD link
                    self.guessXMLRPCURLFromHTMLURL(originalXMLRPCURL, success: success, failure: { (error) in
                        DDLogError(error.localizedDescription)
                        // See if this is a Jetpack site that's having problems.
                        if let service = JetpackServiceRemote(wordPressComRestApi: WordPressComRestApi.anonymousApi(userAgent: userAgent)) {
                            service.checkSiteHasJetpack(originalXMLRPCURL, success: { (hasJetpack) in
                                var err = error
                                if hasJetpack {
                                    var userInfo = err.userInfo
                                    userInfo[WordPressOrgXMLRPCValidator.UserInfoHasJetpackKey] = true
                                    err = NSError(domain: err.domain, code: err.code, userInfo: userInfo)
                                }
                                failure(err)
                            }, failure: { (_) in
                                // Return the previous error, not an error when checking for jp.
                                failure(error)
                            })
                        } else {
                            // JetpackServiceRemote didn't init properly, just call failure with the existing error
                            failure(error)
                        }
                    })
                })
            })
    }

    fileprivate func urlForXMLRPCFromURLString(_ urlString: String, addXMLRPC: Bool) throws -> URL {
        var resultURLString = urlString
        // Is an empty url? Sorry, no psychic powers yet
        resultURLString = urlString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if resultURLString.isEmpty {
            throw WordPressOrgXMLRPCValidatorError.emptyURL.convertToNSError()
        }

        // Check if it's a valid URL
        // Not a valid URL. Could be a bad protocol (htpp://), syntax error (http//), ...
        // See https://github.com/koke/NSURL-Guess for extra help cleaning user typed URLs
        guard let baseURL = URL(string: resultURLString) else {
            throw WordPressOrgXMLRPCValidatorError.invalidURL.convertToNSError()
        }

        // Let's see if a scheme is provided and it's HTTP or HTTPS
        var scheme = baseURL.scheme!.lowercased()
        if scheme.isEmpty {
            resultURLString = "http://\(resultURLString)"
            scheme = "http"
        }

        guard scheme == "http" || scheme == "https" else {
            throw WordPressOrgXMLRPCValidatorError.invalidScheme.convertToNSError()
        }

        if baseURL.lastPathComponent != "xmlrpc.php" && addXMLRPC {
            // Assume the given url is the home page and XML-RPC sits at /xmlrpc.php
            DDLogInfo("Assume the given url is the home page and XML-RPC sits at /xmlrpc.php")
            resultURLString = "\(resultURLString)/xmlrpc.php"
        }

        guard let url = URL(string: resultURLString) else {
            throw WordPressOrgXMLRPCValidatorError.invalid.convertToNSError()
        }

        return url
    }

    fileprivate func validateXMLRPCURL(_ url: URL,
                                       redirectCount: Int = 0,
                                   success: @escaping (_ xmlrpcURL: URL) -> (),
                                   failure: @escaping (_ error: NSError) -> ()) {
        guard redirectCount < redirectLimit else {
            let error = NSError(domain: URLError.errorDomain,
                                code: URLError.httpTooManyRedirects.rawValue,
                                userInfo: nil)
            failure(error)
            return
        }
        let api = WordPressOrgXMLRPCApi(endpoint: url)
        api.callMethod("system.listMethods", parameters: nil, success: { (responseObject, httpResponse) in
                guard let methods = responseObject as? [String], methods.contains("wp.getUsersBlogs") else {
                        failure(WordPressOrgXMLRPCValidatorError.notWordPressError.convertToNSError())
                        return
                }
                if let finalURL = httpResponse?.url {
                    success(finalURL)
                } else {
                    failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
                }
            }, failure: { (error, httpResponse) in
                if httpResponse?.url != url {
                    // we where redirected, let's check the answer content
                    if let data = error.userInfo[WordPressOrgXMLRPCApi.WordPressOrgXMLRPCApiErrorKeyData] as? Data,
                        let responseString = String(data: data, encoding: String.Encoding.utf8), responseString.range(of: "<meta name=\"GENERATOR\" content=\"www.dudamobile.com\">") != nil
                            || responseString.range(of: "dm404Container") != nil {
                        failure(WordPressOrgXMLRPCValidatorError.mobilePluginRedirectedError.convertToNSError())
                        return
                    }
                    // If it's a redirect to the same host
                    // and the response is a '405 Method Not Allowed'
                    if let responseUrl = httpResponse?.url,
                        responseUrl.host == url.host
                        && httpResponse?.statusCode == 405 {
                        // Then it's likely a good redirect, but the POST
                        // turned into a GET.
                        // Let's retry the request at the new URL.
                        self.validateXMLRPCURL(responseUrl, redirectCount: redirectCount + 1, success: success, failure: failure)
                        return
                    }
                }
                failure(error)
            })
    }

    fileprivate func guessXMLRPCURLFromHTMLURL(_ htmlURL: URL,
                                           success: @escaping (_ xmlrpcURL: URL) -> (),
                                           failure: @escaping (_ error: NSError) -> ()) {
        DDLogInfo("Fetch the original url and look for the RSD link by using RegExp")
        let session = URLSession(configuration: URLSessionConfiguration.ephemeral)
        let dataTask = session.dataTask(with: htmlURL, completionHandler: { (data, response, error) in
            if let error = error {
                failure(error as NSError)
                return
            }
            guard let data = data,
                  let responseString = String(data: data, encoding: String.Encoding.utf8),
                  let rsdURL = self.extractRSDURLFromHTML(responseString)
            else {
                    failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
                return
            }

            // Try removing "?rsd" from the url, it should point to the XML-RPC endpoint
            let xmlrpc = rsdURL.replacingOccurrences(of: "?rsd", with: "")
            if xmlrpc != rsdURL {
                guard let newURL = URL(string: xmlrpc) else {
                    failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
                    return
                }
                self.validateXMLRPCURL(newURL, success: success, failure: { (error) in
                    //Try to validate by using the RSD file directly
                    failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
                })
            } else {
                //Try to validate by using the RSD file directly
                self.guessXMLRPCURLFromRSD(rsdURL, success: success, failure: failure)
            }
        })
        dataTask.resume()
    }

    fileprivate func extractRSDURLFromHTML(_ html: String) -> String? {
        guard let rsdURLRegExp = try? NSRegularExpression(pattern: "<link\\s+rel=\"EditURI\"\\s+type=\"application/rsd\\+xml\"\\s+title=\"RSD\"\\s+href=\"([^\"]*)\"[^/]*/>",
                                                          options: [.caseInsensitive])
            else {
                return nil
        }

        let matches = rsdURLRegExp.matches(in: html,
                                                   options: NSRegularExpression.MatchingOptions(),
                                                   range: NSMakeRange(0, html.characters.count))
        if matches.count <= 0 {
            return nil
        }
        let rsdURLRange = matches[0].rangeAt(1)
        if rsdURLRange.location == NSNotFound {
            return nil
        }
        let rsdURL = (html as NSString).substring(with: rsdURLRange)
        return rsdURL
    }

    fileprivate func guessXMLRPCURLFromRSD(_ rsd: String,
                                       success: @escaping (_ xmlrpcURL: URL) -> (),
                                       failure: @escaping (_ error: NSError) -> ()) {
        DDLogInfo("Parse the RSD document at the following URL: \(rsd)")
        guard let rsdURL = URL(string: rsd) else {
            failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
            return
        }
        let session = URLSession(configuration: URLSessionConfiguration.ephemeral)
        let dataTask = session.dataTask(with: rsdURL, completionHandler: { (data, response, error) in
            if let error = error {
                failure(error as NSError)
                return
            }
            guard let data = data,
                let responseString = String(data: data, encoding: String.Encoding.utf8),
                let parser = WordPressRSDParser(xmlString: responseString),
                let endpoint = (try? parser.parsedEndpoint()),
                let xmlrpc = endpoint,
                let xmlrpcURL = URL(string: xmlrpc)
                else {
                    failure(WordPressOrgXMLRPCValidatorError.invalid.convertToNSError())
                    return
            }
            DDLogInfo("Bingo! We found the WordPress XML-RPC element: \(xmlrpcURL)")
            self.validateXMLRPCURL(xmlrpcURL, success: success, failure: failure)
        })
        dataTask.resume()
    }
}
