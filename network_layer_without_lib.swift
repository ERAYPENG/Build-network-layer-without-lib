import UIKit

// 配置 EndPoint 所需的資訊
protocol EndPointType {
    var baseURL: URL { get }
    var path: String { get }
    var httpMethod: HTTPMethod { get }
    var task: HTTPTask { get }
    var header: HttpHeaders { get }
}

// 設定 Request 的 HTTP 方法
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public typealias HttpHeaders = [String: String]
public typealias Parameters = [String: Any]

// 負責為特定 endPoint 配置參數
public enum HTTPTask {
    case request
    
    case requestParameters(bodyParameters: Parameters?,
                           urlParameters: Parameters?)

    case requestParametersAndHeaders(bodyParameters: Parameters?,
                                     urlParameters: Parameters?,
                                     additionHeaders: HttpHeaders?)
}

// ParameterEncoder 是一個函式，為參數進行編碼。當方法失敗時，它會顯示錯誤訊息，讓我們處理錯誤狀況。
public protocol ParameterEncoder {
    static func encode(urlRequest: inout URLRequest, with parameters: Parameters) throws // inout 可以使變數定義為 reference type
}

// 建立了一個繼承 Error 的列舉
public enum NetworkError: String, Error {
    case parametersNil = "Parameters were nil."
    case encodingFailed = "Parameters encoding failed."
    case missingURL = "URL is nil."
}

// 將參數編碼為 URL 格式，並安全地傳送
public struct URLParameterEncoder: ParameterEncoder {
    public static func encode(urlRequest: inout URLRequest, with parameters: Parameters) throws {
        guard let url = urlRequest.url else { throw NetworkError.missingURL }
        
        if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters.isEmpty {
            urlComponents.queryItems = [URLQueryItem]()
            
            for (key, value) in parameters {
                let queryItem = URLQueryItem(name: key,
                                             value: "\(value)".addingPercentEncoding(withAllowedCharacters: .urlHostAllowed))
                urlComponents.queryItems?.append(queryItem)
            }
            urlRequest.url = urlComponents.url
        }
        
        if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
            urlRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
    }
}

// 與 URLParameter 編碼器差不多，但這裡我們將參數編碼為 JSON 格式
public struct JSONParameterEncoder: ParameterEncoder {
    public static func encode(urlRequest: inout URLRequest, with parameters: Parameters) throws {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: parameters, options: .prettyPrinted)
            urlRequest.httpBody = jsonData
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } catch {
            throw NetworkError.encodingFailed
        }
    }
}

public typealias NetworkRouterCompletion = (_ data: Data?, _ response: URLResponse?, _ error: Error?) -> ()

// 製作 NetworkRouter，它有一個 EndPoint，用來製作 Request；一旦製作完成，它會將網路回應送到 Completion。加入 cancel 函式，可以在 Request 的生命週期中隨時呼叫這個函式，取消下載任務。
protocol NetworkRouter: class {
    associatedtype EndPoint: EndPointType
    func request(_ route: EndPoint, completion: @escaping NetworkRouterCompletion)
    func cancel()
}

class Router<EndPoint: EndPointType>: NetworkRouter {
    private var task: URLSessionTask?
    func request(_ route: EndPoint, completion: @escaping NetworkRouterCompletion) {
        let session = URLSession.shared
        do {
            let request = try self.buildRequest(from: route)
            task = session.dataTask(with: request, completionHandler: { (data, response, error) in
                completion(data, response, error)
            })
        } catch {
            completion(nil, nil, error)
        }
        self.task?.resume()
    }
    
    func cancel() {
        self.task?.cancel()
    }
    
    // 建立一個名為 buildRequest 的私有函式，這個函式負責網路層中所有重要的工作，基本上就是將 EndPointType 轉換為 URLRequest
    fileprivate func buildRequest(from route: EndPoint) throws -> URLRequest {
        var request = URLRequest(url: route.baseURL.appendingPathComponent(route.path),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 10.0)
        
        request.httpMethod = route.httpMethod.rawValue
        do {
            switch route.task {
            case .request:
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            case .requestParameters(let bodyParameters,
                                    let urlParameters):
                try self.configureParameters(bodyParameters: bodyParameters, urlParameters: urlParameters, request: &request)
            case .requestParametersAndHeaders(let bodyParameters,
                                              let urlParameters,
                                              let additionHeaders):
                self.addAdditionalHeaders(additionHeaders, request: &request)
                try self.configureParameters(bodyParameters: bodyParameters, urlParameters: urlParameters, request: &request)
            }
            return request
        } catch {
            throw error
        }
    }
    
    // 建立一個名為 configureParameters 的函式，這個函式負責編碼我們的參數
    fileprivate func configureParameters(bodyParameters: Parameters?,
                                         urlParameters: Parameters?,
                                         request: inout URLRequest) throws {
        do {
            if let bodyParameters = bodyParameters {
                try JSONParameterEncoder.encode(urlRequest: &request, with: bodyParameters)
            }
            if let urlParameters = urlParameters {
                try URLParameterEncoder.encode(urlRequest: &request, with: urlParameters)
            }
        } catch {
            throw error
        }
    }
    
    // 建立一個名為 addAdditionalHeaders 的函式，把所有額外的標頭加到 Request 的標頭裡即可
    fileprivate func addAdditionalHeaders(_ additionalHeaders: HttpHeaders?, request: inout URLRequest) {
        guard let headers = additionalHeaders else { return }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}
