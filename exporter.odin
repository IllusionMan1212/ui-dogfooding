package main

import "core:mem"
import "core:strings"

// Inherit is implied if "auth" is not present
PostmanExportAuthType :: enum {
	NoAuth,
	APIKey,
	Basic,
	Token,
}

// Export-only item representations so request items do not serialize an empty
// "item": [] field (Postman treats that as a folder).
PostmanExportRequestItem :: struct {
	name: string `json:"name"`,
	request: PostmanExportRequest `json:"request"`,
}

PostmanExportFolderItem :: struct {
	name: string `json:"name"`,
	auth: Maybe(PostmanExportAuth) `json:"auth,omitempty"`,
	items: [dynamic]PostmanExportItem `json:"item"`,
}

PostmanExportItem :: union {
	PostmanExportRequestItem,
	PostmanExportFolderItem,
}

PostmanExportCollection :: struct {
	info: PostmanCollectionInfo `json:"info"`,
	auth: Maybe(PostmanExportAuth) `json:"auth,omitempty"`,
	items: [dynamic]PostmanExportItem `json:"item"`,
}

PostmanExportEnvironment :: struct {
	name: string `json:"name"`,
	values: [dynamic]PostmanEnvironmentVariable `json:"values"`,
	variable_scope: string `json:"_postman_variable_scope"`,
	exported_using: string `json:"_postman_exported_using"`,
}

PostmanExportUrl :: struct {
	raw: string `json:"raw"`,
	protocol: string `json:"protocol,omitempty"`,
	host: union{
		string,
		[]string,
	} `json:"host,omitempty"`,
	path: union{
		string,
		[]PostmanUrlPath,
	} `json:"path,omitempty"`,
	port: string `json:"port,omitempty"`,
	query: [dynamic]PostmanQueryParam `json:"query,omitempty"`,
	hash: string `json:"hash,omitempty"`,
	variables: [dynamic]PostmanVariable `json:"variable,omitempty"`,
}

AuthField :: struct {
	key: string `json:"key"`,
	value: string `json:"value"`,
	type: string `json:"type"`,
}

PostmanExportAuth :: struct {
	type: string `json:"type"`,
	// The "inherit" type is implicit if "auth" is not present, so we don't need
	// to represent it here.
	apikey: [dynamic]AuthField `json:"apikey,omitempty"`,
	basic: [dynamic]AuthField `json:"basic,omitempty"`,
	bearer: [dynamic]AuthField `json:"bearer,omitempty"`,
}

PostmanExportRequest :: struct {
	url: union{
		PostmanExportUrl,
		string,
	} `json:"url"`,
	auth: Maybe(PostmanExportAuth) `json:"auth,omitempty"`,
	method: string `json:"method"`,
	headers: [dynamic]PostmanHeader `json:"header,omitempty"`,
	body: Maybe(PostmanBody) `json:"body,omitempty"`,
}

@(private="file")
// auth is a pointer here so we're able to pass slices without copying the struct locally which ends with garbage data because of the fixed-size arrays.
export_auth_to_postman :: proc(auth: ^Authorization, scratch_allocator: mem.Allocator) -> (postman_auth: Maybe(PostmanExportAuth)) {
	if auth.type == .InheritFromParent {
		return
	}

	a := PostmanExportAuth{}
	fields := make([dynamic]AuthField, scratch_allocator)

	switch auth.type {
	case .NoAuth:
		a.type = "noauth"
	case .ApiKey:
		a.type = "apikey"
		append(&fields, AuthField{
			key = "key",
			value = auth.api_key_key,
			type = "string",
		})
		append(&fields, AuthField{
			key = "in",
			value = auth.api_key_add_to == .Header ? "header" : "query",
			type = "string",
		})
		append(&fields, AuthField{
			key = "value",
			value = auth.api_key_value,
			type = "string",
		})
		a.apikey = fields
	case .Basic:
		a.type = "basic"
		append(&fields, AuthField{
			key = "username",
			value = auth.basic_username,
			type = "string",
		})
		append(&fields, AuthField{
			key = "password",
			value = auth.basic_password,
			type = "string",
		})
		a.basic = fields
	case .Token:
		// Postman's bearer schema only carries the token (no prefix), so always export
		// the token regardless of bearer_prefix. Gating on the prefix here emitted
		// {"type":""} for the common empty-prefix case, which re-imported as InheritFromParent.
		a.type = "bearer"
		append(&fields, AuthField{
			key = "token",
			value = auth.bearer_token,
			type = "string",
		})
		a.bearer = fields
	case .InheritFromParent:
	}

	postman_auth = a
	return
}

export_collection_to_postman_v21 :: proc(collection: ^Collection, scratch_allocator: mem.Allocator) -> PostmanExportCollection {
	export_request :: proc(req: ^Request, scratch_allocator: mem.Allocator) -> PostmanExportItem {
		postman_req := PostmanExportRequest{}
		postman_req.headers = make([dynamic]PostmanHeader, scratch_allocator)
		postman_req.method = http_method_string(req.method)

		for &header in req.headers {
			key := header.key
			value := header.value
			if key == "" && value == "" {
				continue
			}

			append(&postman_req.headers, PostmanHeader{
				key = key,
				value = value,
				disabled = header.disabled,
			})
		}

		url := PostmanExportUrl{}
		url.query = make([dynamic]PostmanQueryParam, scratch_allocator)
		url.variables = make([dynamic]PostmanVariable, scratch_allocator)
		url.raw = strings.to_string(req.url)

		// Export both the raw URL and decomposed URL components expected by Postman.
		url_without_hash := url.raw
		hash_split := strings.split_n(url.raw, "#", 2, allocator = scratch_allocator)
		if len(hash_split) > 1 {
			url_without_hash = hash_split[0]
			url.hash = hash_split[1]
		}

		url_without_query := url_without_hash
		query_split := strings.split_n(url_without_hash, "?", 2, allocator = scratch_allocator)
		if len(query_split) > 1 {
			url_without_query = query_split[0]
		}

		remainder := url_without_query
		scheme_split := strings.split_n(url_without_query, "://", 2, allocator = scratch_allocator)
		if len(scheme_split) > 1 {
			url.protocol = scheme_split[0]
			remainder = scheme_split[1]
		}

		authority := remainder
		path := ""
		slash_split := strings.split_n(remainder, "/", 2, allocator = scratch_allocator)
		if len(slash_split) > 1 {
			authority = slash_split[0]
			path = slash_split[1]
		}

		// Strip userinfo if present (user:pass@host).
		at_split := strings.split_n(authority, "@", 2, allocator = scratch_allocator)
		host_port := authority
		if len(at_split) > 1 {
			host_port = at_split[1]
		}

		host := host_port
		if strings.starts_with(host_port, "[") {
			// IPv6 literal: [addr]:port
			close_idx := strings.index(host_port, "]")
			if close_idx >= 0 {
				host = host_port[:close_idx+1]
				if close_idx+1 < len(host_port) && host_port[close_idx+1] == ':' {
					url.port = host_port[close_idx+2:]
				}
			}
		} else {
			port_split := strings.split_n(host_port, ":", 2, allocator = scratch_allocator)
			host = port_split[0]
			if len(port_split) > 1 {
				url.port = port_split[1]
			}
		}

		url.host = host
		url.path = path

		for &param in req.query_params {
			key := param.key
			value := param.value
			if key == "" {
				continue
			}

			append(&url.query, PostmanQueryParam{
				key = key,
				value = value,
				disabled = param.disabled,
			})
		}

		url_variables := make([dynamic]PostmanVariable, scratch_allocator)
		for key, &path_param in req.path_params {
			append(&url_variables, PostmanVariable{
				id = key,
				key = key,
				value = path_param.value,
				type = "string",
				name = key,
				system = false,
				disabled = false,
			})
		}
		url.variables = url_variables

		postman_req.url = url

		postman_req.auth = export_auth_to_postman(&req.auth, scratch_allocator)

		switch req.body.type {
		case .None: // no-op
		case .Text, .JSON, .HTML, .XML:
			body := PostmanBody{}
			body.mode = "raw"
			body.raw = strings.to_string(req.body.text)
			#partial switch req.body.type {
			case .Text: body.options.raw.language = "text"
			case .JSON: body.options.raw.language = "json"
			case .HTML: body.options.raw.language = "html"
			case .XML: body.options.raw.language = "xml"
			}
			postman_req.body = body
		case .X_WWW_Form_Urlencoded:
			body := PostmanBody{}
			body.mode = "urlencoded"
			body.urlencoded = make([dynamic]PostmanUrlEncodedParameter, scratch_allocator)
			for &field in req.body.structured {
				key := field.key
				value := field.value
				if key == "" && value == "" {
					continue
				}
				append(&body.urlencoded, PostmanUrlEncodedParameter{
					key = key,
					value = value,
					disabled = field.disabled,
				})
			}
			postman_req.body = body
		case .Form:
			body := PostmanBody{}
			body.mode = "formdata"
			body.formdata = make([dynamic]PostmanFormParameter, scratch_allocator)
			for &field in req.body.structured {
				key := field.key
				value := field.value
				content_type := field.content_type
				if key == "" && value == "" && content_type == "" {
					continue
				}

				form := PostmanFormParameter{
					key = key,
					content_type = content_type,
					disabled = field.disabled,
				}

				if field.is_file {
					form.type = "file"
					path := value
					if path != "" {
						form.src = path
					}
				} else {
					form.type = "text"
					form.value = value
				}

				append(&body.formdata, form)
			}
			postman_req.body = body
		case .File:
			body := PostmanBody{}
			body.mode = "file"
			if req.body.binary_path != "" {
				body.file.src = req.body.binary_path
			}
			postman_req.body = body
		}

		return PostmanExportRequestItem{
			name = req.name,
			request = postman_req,
		}
	}

	export_collection_item :: proc(src: ^Collection, scratch_allocator: mem.Allocator) -> PostmanExportItem {
		item := PostmanExportFolderItem{name = src.name}
		item.auth = export_auth_to_postman(&src.auth, scratch_allocator)
		item.items = make([dynamic]PostmanExportItem, scratch_allocator)

		for i := 0; i < len(src.requests); i += 1 {
			append(&item.items, export_request(&src.requests[i], scratch_allocator))
		}

		for child := src.first; child != nil; child = child.next {
			append(&item.items, export_collection_item(child, scratch_allocator))
		}

		return item
	}

	postman := PostmanExportCollection{}
	postman.items = make([dynamic]PostmanExportItem, scratch_allocator)
	postman.info.name = collection.name
	postman.info.schema = POSTMAN_SCHEMA_STRING
	postman.auth = export_auth_to_postman(&collection.auth, scratch_allocator)

	for i := 0; i < len(collection.requests); i += 1 {
		append(&postman.items, export_request(&collection.requests[i], scratch_allocator))
	}

	for child := collection.first; child != nil; child = child.next {
		append(&postman.items, export_collection_item(child, scratch_allocator))
	}

	return postman
}

export_environment :: proc(environment: ^Environment, scratch_allocator: mem.Allocator) -> (env: PostmanExportEnvironment) {
	env.values = make([dynamic]PostmanEnvironmentVariable, scratch_allocator)
	env.variable_scope = "environment"
	env.exported_using = "moonladder-" + VERSION
	env.name = environment.name

	for &field in environment.variables {
		var := PostmanEnvironmentVariable{}
		var.enabled = field.enabled
		var.type = "default"
		var.key = field.variable
		var.value = field.value

		append(&env.values, var)
	}

	return
}
