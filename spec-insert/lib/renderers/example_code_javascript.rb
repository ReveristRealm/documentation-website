# frozen_string_literal: true

require 'json'
require_relative "./components/base_mustache_renderer"

class ExampleCodeJavaScript < BaseMustacheRenderer
  self.template_file = "#{__dir__}/templates/example_code.javascript.mustache"

  def initialize(action, args)
    super(action, args)
  end

  def call_code
    return "// Invalid action" unless @action&.full_name

    client_setup = <<~JS
      import { Client } from '@opensearch-project/opensearch';

      const client = new Client({
        node: 'https://localhost:9200',
        auth: { username: 'admin', password: 'admin' }, // For testing only. Don't store credentials in code.
        ssl: { rejectUnauthorized: false }
      });

    JS

    parts = @action.full_name.split('.')
    client_call = "client"

    if parts.length == 2
      namespace, method = parts
      client_call += ".#{namespace}.#{method}"
    else
      namespace = parts[0]
      client_call += ".#{namespace}"
    end

    # ---- Build argument object: path params + query params + body ----
    rest       = @args.rest
    http_verb  = rest.verb
    full_path  = [rest.path, rest.query&.map { |k, v| "#{k}=#{v}" }.join('&')].compact.join('?')

    path_part, query_string = full_path.to_s.split('?', 2)
    path_values  = path_part.split('/').reject(&:empty?)

    spec_path  = match_spec_path(full_path)
    spec_parts = spec_path.split('/').reject(&:empty?)

    param_mapping = {}
    spec_parts.each_with_index do |part, i|
      if part =~ /\{(.+?)\}/ && path_values[i]
        param_mapping[$1] = path_values[i]
      end
    end

    # Arg object (single JS object literal)
    props = []

    @action.path_parameters.each do |param|
      next unless param_mapping.key?(param.name)
      # String literals in JS
      props << "#{safe_js_key(param.name)}: #{js_string(param_mapping[param.name])}"
    end

    if query_string
      query_pairs = query_string.split('&').map { |s| s.split('=', 2) }
      query_pairs.each do |k, v|
        next if k.nil? || k.empty?
        # Mirror your Python renderer: keep values as strings
        props << "#{safe_js_key(k)}: #{js_string(v)}"
      end
    end

    body = rest.body
    if expects_body?(http_verb)
      raw_body = @args.raw['body']
      if body
        begin
          parsed = JSON.parse(raw_body)
          pretty = JSON.pretty_generate(parsed)
          props << "body: #{pretty}"
        rescue JSON::ParserError
          if raw_body&.include?("\n") && looks_like_ndjson?(raw_body)
            # NDJSON → template literal
            props << "body: ndjson"
          elsif raw_body&.include?("\n")
            # Multiline but not valid JSON → still send as string
            props << "body: `\n#{raw_body.rstrip}\n`"
          else
            props << "body: #{js_string(raw_body)}"
          end
        end
      else
        props << "body: { /* Insert body here */ }"
      end
    end

    # Optional NDJSON helper (only if needed)
    ndjson_helper = ""
    if expects_body?(http_verb) && body && raw_looks_like_ndjson?(@args.raw['body'])
      ndjson_text = @args.raw['body'].to_s.rstrip
      ndjson_helper = <<~JS
        const ndjson = String.raw`
        #{ndjson_text}
        `;
      JS
    end

    arg_object = props.empty? ? "" : "{\n#{indent_props(props)}\n}"

    js_call =
      if props.empty?
        "const response = await #{client_call}();"
      else
        "const response = await #{client_call}(#{arg_object});"
      end

    body_js = <<~JS
      #{ndjson_helper}async function run() {
        #{js_call}
      }
   
    JS

    if @args.include_client_setup
      client_setup + body_js
    else
      body_js
    end
  end

  private

  def expects_body?(verb)
    verb = verb.to_s.downcase
    @action.operations.any? do |op|
      op.http_verb.to_s.downcase == verb &&
        op.spec&.requestBody &&
        op.spec.requestBody.respond_to?(:content)
    end
  end

  def match_spec_path(full_path)
    request_path = full_path.to_s.split('?').first.to_s
    request_segments = request_path.split('/').reject(&:empty?)

    best = ''
    best_score = -1

    @action.urls.each do |spec_path|
      spec_segments = spec_path.split('/').reject(&:empty?)
      next unless spec_segments.size == request_segments.size

      score = 0
      spec_segments.each_with_index do |seg, i|
        if seg.start_with?('{')
          score += 1
        elsif seg == request_segments[i]
          score += 2
        else
          score = -1
          break
        end
      end

      if score > best_score
        best = spec_path
        best_score = score
      end
    end

    best
  end

  # ---------- helpers ----------
  def safe_js_key(k)
    k = k.to_s
    k.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? k : "'#{k}'"
  end

  def js_string(v)
    v = v.to_s
    v = "" if v.nil?
    "'#{v.gsub("'", "\\\\'")}'"
  end

  def indent_props(lines)
    lines.map { |l| "  #{l}" }.join(",\n")
  end

  def looks_like_ndjson?(text)
    return false unless text
    lines = text.strip.split("\n")
    return false if lines.size < 2
    jsonish = lines.count { |l| l.strip.start_with?('{', '[') }
    jsonish >= 2
  end

  def raw_looks_like_ndjson?(text)
    looks_like_ndjson?(text)
  end
end