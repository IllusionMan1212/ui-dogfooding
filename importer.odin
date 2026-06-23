package main

import "core:mem"
import "core:encoding/json"
import "core:math/rand"
import "core:log"
import "core:strings"
import "core:os"

POSTMAN_SCHEMA_STRING :: "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
POSTMAN_ENV_STRING_IDENTIFIER :: "_postman_exported_using"
INSOMNIA_V4_STRING_IDENTIFIER :: "insomnia.desktop.app"

Schema :: enum {
	Unknown,
	Postman,
	InsomniaV4,
	// HoppscotchV11,
}

PostmanCollectionInfo :: struct {
	name: string `json:"name"`,
	schema: string `json:"schema"`
}

PostmanUrlPath :: union{
	string,
	struct {
		type: string,
		value: string,
	}
}

PostmanQueryParam :: struct {
	key: Maybe(string) `json:"key"`,
	value: Maybe(string) `json:"value"`,
	disabled: bool `json:"disabled,omitempty"`
}

PostmanVariable :: struct {
	id: string `json:"id"`,
	key: string `json:"key"`,
	value: string `json:"value"`,
	type: string `json:"type,omitempty"`, // enum of "string", "boolean", "any", "number"
	name: string `json:"name,omitempty"`,
	system: bool `json:"system,omitempty"`,
	disabled: bool `json:"disabled,omitempty"`,
}

PostmanUrl :: struct {
	raw: string `json:"raw"`,
	protocol: string `json:"protocol"`,
	host: union{
		string,
		[]string, // the host split into an array of subdomains.
	} `json:"host"`,
	path: union{
		string,
		[]PostmanUrlPath,
	} `json:"path"`,
	port: string `json:"port"`, // Empty value implies 80/443 depending on whether the protocol field contains http/https.
	query: []PostmanQueryParam `json:"query"`,
	hash: string `json:"hash"`,
	variables: []PostmanVariable `json:"variable"`,
}

PostmanHeader :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	disabled: bool `json:"disabled,omitempty"`,
}

PostmanUrlEncodedParameter :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	disabled: bool `json:"disabled,omitempty"`,
}

PostmanFormParameter :: struct {
	key: string `json:"key"`,
	content_type: string `json:"contentType,omitempty"`,
	disabled: bool `json:"disabled,omitempty"`,
	type: string `json:"type"`, // enum of "text", "file"

	value: string `json:"value,omitempty"`, // Only filled when "type" is "text"
	// Only filled when "type" is "file"
	// NOTE: schema says this can be an array but an array of what?
	// I've noticed its an empty array when no file is selected but that's it???
	src: union{
		string,
		[]struct{},
	} `json:"src,omitempty"`,
}

PostmanBodyOptions :: struct {
	raw: struct{
		language: string `json:"language"` // enum of "json", "html", "xml", "text", "javascript"
	} `json:"raw"`,
}

PostmanFile :: struct {
	src: Maybe(string) `json:"src"`, // if this starts with postman-cloud:/// then this is a cloud file that we can't retrieve.
	content: string `json:"content"`, // No idea what this contains.
}

PostmanBody :: struct {
	mode: string `json:"mode"`, // enum of "raw", "urlencoded", "formdata", "file", "graphql"
	raw: string `json:"raw,omitempty"`,
	urlencoded: [dynamic]PostmanUrlEncodedParameter `json:"urlencoded,omitempty"`,
	formdata: [dynamic]PostmanFormParameter `json:"formdata,omitempty"`,
	file: PostmanFile `json:"file,omitempty"`,
	// graphql: NOTE: Schema doesn't mention the keys in the object. Need an example.
	options: PostmanBodyOptions `json:"options,omitempty"`,
	disabled: bool `json:"disabled,omitempty"`,
}

PostmanAuth :: struct {
	type: string `json:"type"`, // enum of "noauth", "basic", "bearer", "apikey", etc..
	basic: [dynamic]AuthField `json:"basic,omitempty"`,
	bearer: [dynamic]AuthField `json:"bearer,omitempty"`,
	apikey: [dynamic]AuthField `json:"apikey,omitempty"`,
}

PostmanRequest :: struct {
	url: union{
		PostmanUrl,
		string,
	} `json:"url"`,
	// If this is omitted, it is "inherit from parent"
	auth: Maybe(PostmanAuth) `json:"auth,omitempty"`,
	method: string `json:"method"`, // enum of a bunch of methods, could also be a custom method.
	// TODO: header is a union of this array and a string ???
	headers: []PostmanHeader `json:"header"`,
	body: Maybe(PostmanBody) `json:"body"`,
}

PostmanCollectionItem :: struct {
	name: string `json:"name"`,
	auth: Maybe(PostmanAuth) `json:"auth,omitempty"`,
	request: union{ // This union unmarshals correctly because it's two different distinct types.
		PostmanRequest,
		string, // When string, the string is the url of the request and the method is assumed to be GET.
	} `json:"request"`,
	items: []PostmanCollectionItem `json:"item"`
}


// NOTE: we can't simply make two different structs for item and item-group
// and make a union of those because the unmarshaller does a first-fit search
// See: https://github.com/odin-lang/Odin/issues/3474
// Instead I just merge both structs into one and check if the nested `items` is an
// empty array which seems to work fine.
PostmanCollection :: struct {
	info: PostmanCollectionInfo `json:"info"`,
	auth: Maybe(PostmanAuth) `json:"auth,omitempty"`,
	items: []PostmanCollectionItem `json:"item"`,
	variables: []PostmanVariable `json:"variable"`,
}

PostmanEnvironmentVariable :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	type: string `json:"type"`,
	enabled: bool `json:"enabled"`,
}

PostmanEnvironment :: struct {
	name: string `json:"name"`,
	values: []PostmanEnvironmentVariable `json:"values"`,
}

InsomniaV4Parameter :: struct {
	name: string `json:"name"`,
	value: string `json:"value"`
}

InsomniaV4Header :: struct {
	name: string `json:"name"`,
	value: string `json:"value"`,
}

InsomniaV4BodyParam :: struct {
	name: string `json:"name"`,
	value: string `json:"value"`,
}

InsomniaV4Body :: struct {
	// enum of "application/json", "" (plain text if "text" is not empty), "application/x-www-form-urlencoded", "multipart/form-data"
	// "text/xml", "text/html" (assuming)
	mime_type: string `json:"mimeType"`,
	text: string `json:"text"`,
	params: []InsomniaV4BodyParam `json:"params"`,
}

InsomniaV4Authentication :: struct {
	// enum of "none", "basic", "bearer", "apikey", etc..
	type: string `json:"type,omitempty"`,
	disabled: bool `json:"disabled,omitempty"`,
	// Only applicable for basic auth. Indicates whether the username and password are encoded in ISO-8859-1 instead of UTF-8.
	// Moonladder assumes UTF-8 encoding so this is unused.
	useISO8559_1: bool `json:"useISO88591,omitempty"`,
	username: string `json:"username,omitempty"`,
	password: string `json:"password,omitempty"`,

	// Only applicable for bearer auth
	token: string `json:"token,omitempty"`,
	// Unused
	prefix: string `json:"prefix,omitempty"`,

	// Only applicable for API key auth
	key: string `json:"key,omitempty"`,
	value: string `json:"value,omitempty"`,
	// enum of "header", "queryParams", "cookie"
	add_to: string `json:"addTo,omitempty"`,
}

InsomniaV4Resource :: struct {
	id: string `json:"_id"`,
	parent_id: string `json:"parentId"`,
	name: string `json:"name"`,
	type: string `json:"_type"`, // enum of "request", "request_group", "workspace", "environment", "cookie_jar", "api_spec"

	// request-specific
	url: string `json:"url"`,
	method: string `json:"method"`,
	body: InsomniaV4Body `json:"body"`,
	// query params
	parameters: []InsomniaV4Parameter `json:"parameters"`,
	path_parameters: []InsomniaV4Parameter `json:"pathParameters"`,
	headers: []InsomniaV4Header `json:"headers"`,
	authentication: InsomniaV4Authentication `json:"authentication"`,

	// workspace-specific
	scope: string `json:"scope"`,
}

InsomniaV4Collection :: struct {
	resources: []InsomniaV4Resource `json:"resources"`
}

HoppscotchV11QueryParam :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	active: bool `json:"active"`,
	description: string `json:"description"`,
}

HoppscotchV11Header :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	active: bool `json:"active"`,
	description: string `json:"description"`,
}

HoppscotchV11FormField :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	active: bool `json:"active"`,
	is_file: bool `json:"isFile"`,
}

HoppscotchV11RequestBody :: struct {
	content_type: Maybe(string) `json:"contentType"`,
	body: union{
		string, // when application/json and when application/x-www-form-urlencoded (basically just the bulk-edit version)
		[]HoppscotchV11FormField, // when multipart/form-field
		map[string]string, // when application/octet-stream
	} `json:"body"`,
}

HoppscotchV11Request :: struct {
	version: string `json:"v"`,
	name: string `json:"name"`,
	method: string `json:"method"`,
	endpoint: string `json:"endpoint"`,
	// NOTE: query params can be split between this slice and as regular text in the endpoint.
	query: []HoppscotchV11QueryParam `json:"params"`,
	headers: []HoppscotchV11Header `json:"headers"`,
	pre_request_script: string `json:"preRequestScript"`,
	post_request_script: string `json:"testScript"`,
	// auth:
	body: HoppscotchV11RequestBody `json:"body"`,
	// variables: []??? `json:"requestVariables"`,
	//saved_responses: map[string]HoppscotchV11Response `json:"responses"`,
	description: Maybe(string) `json:"description"`,
}

HoppscotchV11Collection :: struct {
	version: int `json:"v"`,
	name: string `json:"name"`,
	folders: []HoppscotchV11Collection `json:"folders"`,
	requests: []HoppscotchV11Request `json:"requests"`,
	// auth:
	headers: []HoppscotchV11Header `json:"headers"`,
	// variables: []
	description: string `json:"description"`,
}

HoppscotchV11Root :: union {
	[]HoppscotchV11Collection,
	HoppscotchV11Collection,
}

detect_collection_schema :: proc(data: []byte, scratch_allocator: mem.Allocator) -> (schema: Schema, err: json.Error) {
	value := json.parse(data, parse_integers = true, allocator = scratch_allocator) or_return

	if v, ok := value.(json.Object); ok {
		info, ok := v["info"].(json.Object)
		if ok {
			schema := info["schema"]
			if schema, ok := schema.(json.String); ok && schema == POSTMAN_SCHEMA_STRING {
				return .Postman, nil
			}
		}

		if format, ok := v["__export_format"].(json.Integer); ok && format == 4 {
			if source, ok := v["__export_source"].(json.String); ok && strings.starts_with(source, INSOMNIA_V4_STRING_IDENTIFIER) {
				return .InsomniaV4, nil
			}
		}
	}

	return
}

import_postman_collection :: proc(data: []byte, scratch_allocator: mem.Allocator) -> (collection: ^Collection, err: json.Unmarshal_Error) {
	postman_collection: PostmanCollection
	json.unmarshal(data, &postman_collection, allocator = scratch_allocator) or_return

	parse_postman_auth :: proc(auth: PostmanAuth, name: string, entity: string) -> Authorization {
		parsed := Authorization{}

		switch auth.type {
		case "noauth":
			parsed.type = .NoAuth
		case "basic":
			parsed.type = .Basic

			if len(auth.basic) == 0 {
				log.warnf("Basic auth with no fields for %s \"%s\".", entity, name)
				break
			}

			for field in auth.basic {
				if field.key == "username" {
					copy(parsed.basic_username[:], field.value)
				} else if field.key == "password" {
					copy(parsed.basic_password[:], field.value)
				}
			}
		case "bearer":
			parsed.type = .Token
			if len(auth.bearer) == 0 {
				log.warnf("Bearer auth with no token for %s \"%s\".", entity, name)
				break
			}

			for field in auth.bearer {
				if field.key == "token" {
					copy(parsed.bearer_token[:], field.value)
					break
				}
			}
		case "apikey":
			parsed.type = .ApiKey

			for field in auth.apikey {
				if field.key == "key" {
					copy(parsed.api_key_key[:], field.value)
				} else if field.key == "value" {
					copy(parsed.api_key_value[:], field.value)
				} else if field.key == "in" {
					if field.value == "header" {
						parsed.api_key_add_to = .Header
					} else if field.value == "query" {
						parsed.api_key_add_to = .QueryParam
					}
				}
			}
		case:
			log.warnf("Unsupported auth type \"%s\" for %s \"%s\". Setting auth to InheritFromParent", auth.type, entity, name)
		}

		return parsed
	}

	import_request :: proc(item: PostmanCollectionItem, scratch_allocator: mem.Allocator) -> Request {
		request := Request{id = rand.int63()}
		copy(request.name[:], item.name)
		switch req in item.request {
		case string:
			strings.write_string(&request.url, req)
		case PostmanRequest:
			switch url in req.url {
			case string:
				strings.write_string(&request.url, url)
			case PostmanUrl:
				split := strings.split_n(url.raw, "?", 2, allocator = scratch_allocator)
				url_no_query := split[0]
				strings.write_string(&request.url, url_no_query)

				for param in url.query {
					p := QueryParam{id = rand.int63()}
					p.disabled = param.disabled
					if key, ok := param.key.(string); ok {
						copy(p.key[:], key)
					}
					if value, ok := param.value.(string); ok {
						copy(p.value[:], value)
					}

					append(&request.query_params, p)
				}

				// Import path params: scan URL for :key patterns and match to variables
				import_path_params_from_url(&request, url.variables, scratch_allocator)
			}

			switch req.method {
			case "GET": request.method = .Get
			case "PUT": request.method = .Put
			case "POST": request.method = .Post
			case "PATCH": request.method = .Patch
			case "HEAD": request.method = .Head
			case "TRACE": request.method = .Trace
			case "DELETE": request.method = .Delete
			case "CONNECT": request.method = .Connect
			case "OPTIONS": request.method = .Options
			case:
				log.warnf("Unsupported method \"%s\" for request \"%s\". Setting method to GET", req.method, item.name)
			}

			if auth, ok := req.auth.?; ok {
				request.auth = parse_postman_auth(auth, item.name, "request")
			}

			for header in req.headers {
				h := RequestHeader{id = rand.int63()}
				copy(h.key[:], header.key)
				copy(h.value[:], header.value)
				h.disabled = header.disabled
				append(&request.headers, h)
			}

			if body, ok := req.body.(PostmanBody); ok {
				switch body.mode {
				case "raw":
					request.body.type = .Text
					request.body.text = strings.builder_make_len_cap(0, 1024)
					strings.write_string(&request.body.text, body.raw)

					switch body.options.raw.language {
					case "text": // no-op since it's already .Text
					case "json":
						request.body.type = .JSON
					case "html":
						request.body.type = .HTML
					case "xml":
						request.body.type = .XML
					case "": // no-op so we don't spam the log
					case:
						log.warnf("Unsupported language for textual body \"%s\" for request \"%s\". Setting body type to text", body.options.raw.language, item.name)
					}
				case "urlencoded":
					request.body.type = .X_WWW_Form_Urlencoded
					request.body.structured = make([dynamic]FormField)
					for field in body.urlencoded {
						f := FormField{id = rand.int63()}
						copy(f.key[:], field.key)
						copy(f.value[:], field.value)
						f.disabled = field.disabled
						append(&request.body.structured, f)
					}
				case "formdata":
					request.body.type = .Form
					request.body.structured = make([dynamic]FormField)
					for field in body.formdata {
						f := FormField{id = rand.int63()}
						copy(f.key[:], field.key)
						if field.content_type != "" {
							copy(f.content_type[:], field.content_type)
						}
						f.disabled = field.disabled

						if field.type == "file" {
							f.is_file = true
							switch src in field.src {
							case string:
								if strings.starts_with(src, "postman-cloud:///") {
									log.warnf("Can't import postman-cloud file for request \"%s\" for form field with key \"%s\"", item.name, field.key)
								} else {
									copy(f.value[:], src)
								}
							case []struct{}:
								log.warnf("Unsupported array value for body file type for request \"%s\" for form field with key \"%s\". Setting value to none", item.name, field.key)
							}
						} else {
							copy(f.value[:], field.value)
						}

						append(&request.body.structured, f)
					}
				case "file":
					request.body.type = .File
					if src, ok := body.file.src.?; ok {
						if strings.starts_with(src, "postman-cloud:///") {
							log.warnf("Can't import postman-cloud file for request \"%s\"", item.name)
						} else {
							fi, err := os.stat(src, context.allocator)
							if err != nil {
								log.warnf("Failed to stat body file for request \"%s\". Setting value to none. Reason: %v", item.name, err)
							} else {
								request.body.binary_path = strings.clone(src)
								os.file_info_delete(fi, context.allocator)
							}
						}
					}
				case:
					log.warnf("Unsupported body type \"%s\" for request \"%s\". Setting body to none", body.mode, item.name)
				}
			}
		}

		return request
	}

	import_path_params_from_url :: proc(request: ^Request, variables: []PostmanVariable, scratch_allocator: mem.Allocator) {
		url_str := strings.clone(strings.to_string(request.url), scratch_allocator)
		path_end := len(url_str)
		for i := 0; i < len(url_str); i += 1 {
			if url_str[i] == '?' || url_str[i] == '#' {
				path_end = i
				break
			}
		}

		path := url_str[:path_end]

		for i := 0; i < len(path); i += 1 {
			if path[i] == ':' && i > 0 && path[i-1] == '/' {
				j := i + 1
				for j < len(path) && is_path_param_char(path[j]) {
					j += 1
				}

				if j > i + 1 {
					key := path[i+1:j]
					index := PathParamIndex{start = i, end = j}

					if p, ok := request.path_params[key]; ok {
						append(&p.indices, index)
						request.path_params[key] = p
					} else {
						p := PathParam{}
						p.indices = make([dynamic]PathParamIndex)
						append(&p.indices, index)

						// Look up variable value from the source data
						for variable in variables {
							variable_key := variable.key if variable.key != "" else variable.id
							if variable_key == key {
								copy(p.value[:], variable.value)
								break
							}
						}

						request.path_params[strings.clone(key)] = p
					}

					i = j - 1
					continue
				}
			}
		}
	}

	build_collection :: proc(postman_collection: PostmanCollectionItem, scratch_allocator: mem.Allocator) -> ^Collection {
		collection := new(Collection, state.collection_allocator)
		collection.id = rand.int63()
		collection.name = strings.clone(postman_collection.name, state.collection_allocator)
		collection.requests = make([dynamic]Request, state.collection_allocator)
		if auth, ok := postman_collection.auth.?; ok {
			collection.auth = parse_postman_auth(auth, postman_collection.name, "collection")
		}

		for item in postman_collection.items {
			if len(item.items) == 0 { // This item is a request
				request := import_request(item, scratch_allocator)
				request.collection = collection
				request.modification_hash = hash_request(&request)

				append(&collection.requests, request)
			} else { // This item is a collection
				child := build_collection(item, scratch_allocator)

				child.parent = collection
				child.prev = collection.last
				child.next = nil
				if collection.first == nil {
					collection.first = child
					collection.last = child
				} else {
					collection.last.next = child
					collection.last = child
				}
			}
		}

		return collection
	}

	collection = new(Collection, state.collection_allocator)
	collection.id = rand.int63()
	collection.name = strings.clone(postman_collection.info.name, state.collection_allocator)
	collection.requests = make([dynamic]Request, state.collection_allocator)
	if auth, ok := postman_collection.auth.?; ok {
		collection.auth = parse_postman_auth(auth, postman_collection.info.name, "collection")
	}

	for item in postman_collection.items {
		if len(item.items) == 0 { // This item is a request
			request := import_request(item, scratch_allocator)
			request.collection = collection
			request.modification_hash = hash_request(&request)

			append(&collection.requests, request)
		} else { // This item is a collection
			child := build_collection(item, scratch_allocator)

			child.parent = collection
			child.prev = collection.last
			child.next = nil
			if collection.first == nil {
				collection.first = child
				collection.last = child
			} else {
				collection.last.next = child
				collection.last = child
			}
		}
	}

	return
}

import_insomnia_v4_collection :: proc(data: []byte, scratch_allocator: mem.Allocator) -> (collection: ^Collection, err: json.Unmarshal_Error) {
	insomnia_collection: InsomniaV4Collection
	json.unmarshal(data, &insomnia_collection, allocator = scratch_allocator) or_return

	workspace: Maybe(InsomniaV4Resource)
	folders := make([dynamic]InsomniaV4Resource, scratch_allocator)
	requests := make([dynamic]InsomniaV4Resource, scratch_allocator)

	for res in insomnia_collection.resources {
		switch res.type {
		case "request":
			append(&requests, res)
		case "request_group":
			append(&folders, res)
		case "workspace":
			workspace = res
		case "environment": // no-op until we support envs
		case "cookie_jar": // no-op until we support cookies
		case "api_spec": // no-op ??
		case:
			log.warnf("Unrecognized resource type for insomnia v4: \"%s\"", res.type)
		}
	}

	if workspace == nil {
		return nil, nil
	}

	collection = new(Collection, state.collection_allocator)
	collection.id = rand.int63()
	collection.name = strings.clone(workspace.?.name, state.collection_allocator)
	collection.requests = make([dynamic]Request, state.collection_allocator)

	mapped_folders := make(map[string]^Collection, scratch_allocator)
	mapped_folders[workspace.?.id] = collection

	for folder in folders {
		if folder.id == "" {
			log.warnf("Ignoring collection with an empty id: \"%s\"", folder.name)
			continue
		}

		if _, found := mapped_folders[folder.id]; found {
			log.warnf("Ignoring collection with a duplicate id: \"%s\"", folder.name)
			continue
		}

		child := new(Collection, state.collection_allocator)
		child.id = rand.int63()
		child.name = strings.clone(folder.name, state.collection_allocator)
		child.requests = make([dynamic]Request, state.collection_allocator)

		mapped_folders[folder.id] = child
	}

	for request in requests {
		parent, found := mapped_folders[request.parent_id]
		if !found {
			log.warnf("Failed to find parent collection for request \"%s\"", request.name)
			continue
		}

		req := Request{id = rand.int63()}
		copy(req.name[:], request.name)
		strings.write_string(&req.url, request.url)

		for param in request.parameters {
			p := QueryParam{id = rand.int63()}
			copy(p.key[:], param.name)
			copy(p.value[:], param.value)

			append(&req.query_params, p)
		}

		switch request.method {
		case "GET": req.method = .Get
		case "PUT": req.method = .Put
		case "POST": req.method = .Post
		case "PATCH": req.method = .Patch
		case "HEAD": req.method = .Head
		case "TRACE": req.method = .Trace
		case "DELETE": req.method = .Delete
		case "CONNECT": req.method = .Connect
		case "OPTIONS": req.method = .Options
		case:
			log.warnf("Unsupported method \"%s\" for request \"%s\". Setting method to GET", request.method, request.name)
		}

		for header in request.headers {
			h := RequestHeader{id = rand.int63()}
			copy(h.key[:], header.name)
			copy(h.value[:], header.value)
			append(&req.headers, h)
		}

		switch request.authentication.type {
		case "": // Inherit from parent. Same as "none" for now.
		case "none": // no-op
		case "basic":
			req.auth.type = .Basic

			if request.authentication.username != "" {
				copy(req.auth.basic_username[:], request.authentication.username)
			}
			if request.authentication.password != "" {
				copy(req.auth.basic_password[:], request.authentication.password)
			}
		case "bearer":
			req.auth.type = .Token
			if request.authentication.token != "" {
				copy(req.auth.bearer_token[:], request.authentication.token)
			}
			if request.authentication.prefix != "" {
				copy(req.auth.bearer_prefix[:], request.authentication.prefix)
			}
		case "apikey":
			req.auth.type = .ApiKey

			if request.authentication.key != "" {
				copy(req.auth.api_key_key[:], request.authentication.key)
			}
			if request.authentication.value != "" {
				copy(req.auth.api_key_value[:], request.authentication.value)
			}
			switch request.authentication.add_to {
			case "cookie":
				log.warn("API key auth with add_to value of cookie is not supported. Adding the API key to Header")
				fallthrough
			case "header":
				req.auth.api_key_add_to = .Header
			case "queryParams":
				req.auth.api_key_add_to = .QueryParam
			case:
				log.warnf("Unsupported API key add_to value \"%s\" for request \"%s\". Setting add_to to Header", request.authentication.add_to, request.name)
				req.auth.api_key_add_to = .Header
			}
		case:
			log.warnf("Unsupported auth type \"%s\" for request \"%s\". Setting auth to InheritFromParent", request.authentication.type, request.name)
		}

		// Import path params: scan URL for :key patterns and match to Insomnia path_parameters
		{
			url_str := strings.clone(strings.to_string(req.url), scratch_allocator)
			path_end := len(url_str)
			for i := 0; i < len(url_str); i += 1 {
				if url_str[i] == '?' || url_str[i] == '#' {
					path_end = i
					break
				}
			}

			path := url_str[:path_end]

			for i := 0; i < len(path); i += 1 {
				if path[i] == ':' && i > 0 && path[i-1] == '/' {
					j := i + 1
					for j < len(path) && is_path_param_char(path[j]) {
						j += 1
					}

					if j > i + 1 {
						key := path[i+1:j]
						index := PathParamIndex{start = i, end = j}

						if p, ok := req.path_params[key]; ok {
							append(&p.indices, index)
							req.path_params[key] = p
						} else {
							p := PathParam{}
							p.indices = make([dynamic]PathParamIndex)
							append(&p.indices, index)

							// Look up value from Insomnia's path_parameters
							for param in request.path_parameters {
								if param.name == key {
									copy(p.value[:], param.value)
									break
								}
							}

							req.path_params[strings.clone(key)] = p
						}

						i = j - 1
						continue
					}
				}
			}
		}

		// TODO: need a real example with html, xml, and file
		switch request.body.mime_type {
		case "":
			if request.body.text != "" {
				req.body.type = .Text
				req.body.text = strings.builder_make_len_cap(0, 1024)
				strings.write_string(&req.body.text, request.body.text)
			}
		case "application/json":
			req.body.type = .JSON
			req.body.text = strings.builder_make_len_cap(0, 1024)
			strings.write_string(&req.body.text, request.body.text)
		case "text/html":
			req.body.type = .HTML
			req.body.text = strings.builder_make_len_cap(0, 1024)
			strings.write_string(&req.body.text, request.body.text)
		case "text/xml":
			req.body.type = .XML
			req.body.text = strings.builder_make_len_cap(0, 1024)
			strings.write_string(&req.body.text, request.body.text)
		case "application/x-www-form-urlencoded":
			req.body.type = .X_WWW_Form_Urlencoded
			req.body.structured = make([dynamic]FormField)

			for field in request.body.params {
				f := FormField{id = rand.int63()}
				copy(f.key[:], field.name)
				copy(f.value[:], field.value)
				append(&req.body.structured, f)
			}
		case "multipart/form-data":
			req.body.type = .Form
			req.body.structured = make([dynamic]FormField)

			for field in request.body.params {
				f := FormField{id = rand.int63()}
				copy(f.key[:], field.name)
				// TODO: need a real example with field value being file
				copy(f.value[:], field.value)
				append(&req.body.structured, f)
			}
		case:
			log.warnf("Unsupported body type \"%s\" for request \"%s\"", request.body.mime_type, request.name)
		}

		req.collection = parent
		req.modification_hash = hash_request(&req)

		append(&parent.requests, req)
	}

	for folder in folders {
		parent, parent_found := mapped_folders[folder.parent_id]
		if !parent_found {
			log.warnf("Failed to find parent collection for collection \"%s\". We might be leaking memory", folder.name)
			continue
		}

		child, child_found := mapped_folders[folder.id]
		if !child_found {
			log.warnf("Failed to find collection \"%s\" in hashmap. We might be leaking memory", folder.name)
			continue
		}

		child.parent = parent
		child.prev = parent.last
		child.next = nil
		if parent.first == nil {
			parent.first = child
			parent.last = child
		} else {
			parent.last.next = child
			parent.last = child
		}
	}

	return collection, nil
}

import_hoppscotch_v11_collections :: proc(data: []byte, scratch_allocator: mem.Allocator) -> (collections: [dynamic]^Collection, err: json.Unmarshal_Error) {
	root: HoppscotchV11Root
	collections = make([dynamic]^Collection)
	json.unmarshal(data, &root, allocator = scratch_allocator) or_return

	build_collection :: proc(hoppscotch_collection: HoppscotchV11Collection, scratch_allocator: mem.Allocator) -> ^Collection {
		collection := new(Collection, state.collection_allocator)
		collection.id = rand.int63()
		collection.name = strings.clone(hoppscotch_collection.name, state.collection_allocator)
		collection.requests = make([dynamic]Request, state.collection_allocator)

		for hoppscotch_request in hoppscotch_collection.requests {
			request := Request{id = rand.int63()}
			copy(request.name[:], hoppscotch_request.name)
			switch hoppscotch_request.method {
			case "GET": request.method = .Get
			case "PUT": request.method = .Put
			case "POST": request.method = .Post
			case "PATCH": request.method = .Patch
			case "HEAD": request.method = .Head
			case "TRACE": request.method = .Trace
			case "DELETE": request.method = .Delete
			case "CONNECT": request.method = .Connect
			case "OPTIONS": request.method = .Options
			case:
				log.warnf("Unsupported method \"%s\" for request \"%s\". Setting method to GET", hoppscotch_request.method, hoppscotch_request.name)
			}

			parts := strings.split_n(hoppscotch_request.endpoint, "?", 2, allocator = scratch_allocator)
			strings.write_string(&request.url, parts[0])

			if len(parts) > 1 {
				queries := strings.split(parts[1], "&", allocator = scratch_allocator)

				for query in queries {
					p := QueryParam{id = rand.int63()}
					key_value := strings.split_n(query, "=", 2, allocator = scratch_allocator)
					copy(p.key[:], key_value[0])

					if len(key_value) > 1 {
						copy(p.value[:], key_value[1])
					}

					append(&request.query_params, p)
				}
			}

			outer:
			for param in hoppscotch_request.query {
				for &existing_param in request.query_params {
					if mem.compare(existing_param.key[:len(param.key)], transmute([]u8)param.key) == 0 {
						log.warnf("Found a duplicate query param \"%s\". Updating value", param.key)
						copy(existing_param.value[:], param.value)

						continue outer
					}
				}

				p := QueryParam{id = rand.int63()}
				p.disabled = !param.active
				copy(p.key[:], param.key)
				copy(p.value[:], param.value)

				append(&request.query_params, p)
			}

			for header in hoppscotch_request.headers {
				h := RequestHeader{id = rand.int63()}
				copy(h.key[:], header.key)
				copy(h.value[:], header.value)
				h.disabled = !header.active
				append(&request.headers, h)
			}

			// TODO: body

			request.collection = collection
			request.modification_hash = hash_request(&request)

			append(&collection.requests, request)
		}

		for nested in hoppscotch_collection.folders {
			child := build_collection(nested, scratch_allocator)

			child.parent = collection
			child.prev = collection.last
			child.next = nil
			if collection.first == nil {
				collection.first = child
				collection.last = child
			} else {
				collection.last.next = child
				collection.last = child
			}
		}

		return collection
	}

	switch r in root {
	case []HoppscotchV11Collection:
		for h_collection in r {
			if h_collection.version != 11 {
				log.warnf("Skipping Hoppscotch collection \"%s\" with unsupported version \"%v\"", h_collection.name, h_collection.version)
				continue
			}

			collection := build_collection(h_collection, scratch_allocator)
			append(&collections, collection)
		}
	case HoppscotchV11Collection:
		collection := build_collection(r, scratch_allocator)
		append(&collections, collection)
	}

	return
}

detect_environment_schema :: proc(data: []byte) -> (schema: Schema, err: json.Error) {
	value := json.parse(data, parse_integers = true) or_return
	defer json.destroy_value(value)

	if v, ok := value.(json.Object); ok {
		_, exported_using_exists := v[POSTMAN_ENV_STRING_IDENTIFIER]
		variable_scope, variable_scope_exists := v["_postman_variable_scope"].(json.String)
		if exported_using_exists && variable_scope_exists && variable_scope == "environment" {
			return .Postman, nil
		}
	}

	return
}

import_postman_environment :: proc(data: []byte, scratch_allocator: mem.Allocator) -> (environment: Environment, err: json.Unmarshal_Error) {
	postman_environment: PostmanEnvironment

	json.unmarshal(data, &postman_environment, allocator = scratch_allocator) or_return

	environment.id = rand.int63()
	copy(environment.name[:], postman_environment.name)
	for variable in postman_environment.values {
		field := EnvironmentVariableField{enabled = variable.enabled}
		copy(field.variable[:], variable.key)
		copy(field.value[:], variable.value)

		append(&environment.variables, field)
	}

	return
}
