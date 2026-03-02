#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Shopify Metafield Scanner
# ============================================================
# Scans all metafields in a Shopify store and outputs a CSV
# report with size analysis.
#
# Usage:
#   ruby scan_metafields.rb                    # uses ./config.yml
#   ruby scan_metafields.rb -c my_config.yml   # custom config
#   ruby scan_metafields.rb --help
#
# Requirements:
#   Ruby 3.0+ (uses only standard library)
#   Optional: gem install tty-progressbar
# ============================================================

require "net/http"
require "json"
require "yaml"
require "csv"
require "fileutils"
require "optparse"
require "uri"
require "time"

class ShopifyMetafieldScanner
  VERSION = "1.0.0"

  # Maps config resource names → Shopify GraphQL owner types & query roots
  RESOURCE_MAP = {
    "product"          => { owner_type: "PRODUCT",          query_root: "products",         name_field: "title" },
    "product_variant"  => { owner_type: "PRODUCTVARIANT",   query_root: "productVariants",  name_field: "displayName" },
    "collection"       => { owner_type: "COLLECTION",       query_root: "collections",      name_field: "title" },
    "customer"         => { owner_type: "CUSTOMER",         query_root: "customers",        name_field: "displayName" },
    "order"            => { owner_type: "ORDER",            query_root: "orders",           name_field: "name" },
    "draft_order"      => { owner_type: "DRAFTORDER",       query_root: "draftOrders",      name_field: "name" },
    "page"             => { owner_type: "PAGE",             query_root: "pages",            name_field: "title" },
    "article"          => { owner_type: "ARTICLE",          query_root: "articles",         name_field: "title" },
    "blog"             => { owner_type: "BLOG",             query_root: "blogs",            name_field: "title" },
    "company"          => { owner_type: "COMPANY",          query_root: "companies",        name_field: "name" },
    "company_location" => { owner_type: "COMPANYLOCATION",  query_root: "companyLocations", name_field: "name" },
    "location"         => { owner_type: "LOCATION",         query_root: "locations",        name_field: "name" },
    "shop"             => { owner_type: "SHOP",             query_root: nil,                name_field: nil },
  }.freeze

  # ---- Progress Tracking ----

  # Base class — silent, no output
  class NullProgress
    def initialize(label = ""); end
    def tick(count = 1); end
    def update_label(label); end
    def finish(message = nil); end
  end

  # Built-in animated spinner — no gems needed
  class SpinnerProgress
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def initialize(label = "")
      @label = label
      @count = 0
      @frame = 0
      @last_render = Time.now - 1
      @line_length = 0
    end

    def tick(count = 1)
      @count += count
      now = Time.now
      # Throttle to ~10fps to avoid hammering the terminal
      return unless (now - @last_render) >= 0.1

      render
      @last_render = now
    end

    def update_label(label)
      @label = label
      render
    end

    def finish(message = nil)
      clear_line
      if message
        puts "   ✓ #{message}"
      else
        puts "   ✓ #{@label} — #{format_count(@count)} found"
      end
    end

    private

    def render
      @frame = (@frame + 1) % FRAMES.length
      text = "   #{FRAMES[@frame]} #{@label}... #{format_count(@count)} metafields"
      clear_line
      print text
      @line_length = text.length
      $stdout.flush
    end

    def clear_line
      print "\r#{' ' * @line_length}\r" if @line_length > 0
    end

    def format_count(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    end
  end

  # tty-progressbar wrapper — only loaded if gem is available
  class BarProgress
    def initialize(label = "")
      @label = label
      @count = 0
      begin
        require "tty-progressbar"
        @bar = TTY::ProgressBar.new(
          "   :bar :percent | :current metafields | :eta_time remaining",
          total: nil, # indeterminate initially
          width: 30,
          bar_format: :block,
          clear: true,
        )
        @available = true
      rescue LoadError
        puts "   ⚠️  tty-progressbar gem not found — falling back to spinner"
        puts "      Install with: gem install tty-progressbar"
        puts ""
        @fallback = SpinnerProgress.new(label)
        @available = false
      end
    end

    def tick(count = 1)
      if @available
        @count += count
        count.times { @bar.advance }
      else
        @fallback.tick(count)
      end
    end

    def update_label(label)
      @label = label
      @fallback&.update_label(label)
    end

    def finish(message = nil)
      if @available
        @bar.finish
        msg = message || "#{@label} — #{format_count(@count)} found"
        puts "   ✓ #{msg}"
      else
        @fallback.finish(message)
      end
    end

    private

    def format_count(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    end
  end

  def initialize(config_path)
    @config = load_config(config_path)
    @log_level = @config.dig("logging", "level") || "normal"
    @stores = resolve_stores
    @results = []
    @errors = []
    # These get set per-store in connect_store!
    @store = {}
    @base_url = ""
    @headers = {}
  end

  def run
    log_info("🔍 Shopify Metafield Scanner v#{VERSION}")
    log_info("📦 Stores: #{@stores.map { |s| s['domain'] }.join(', ')}")
    log_info("⚙️  Method: #{scan_method}")
    log_info("")

    validate_global_config!

    multi = @stores.size > 1

    @stores.each_with_index do |store, store_idx|
      if multi
        log_info("")
        log_info("━" * 60)
        log_info("🏪 [#{store_idx + 1}/#{@stores.size}] #{store['domain']}")
        log_info("━" * 60)
      end

      @results = []
      @errors = []

      connect_store!(store, store_idx)

      enabled = enabled_resources
      total_resources = enabled.size
      enabled.each_with_index do |resource_name, idx|
        log_info("") if idx > 0
        log_info("📂 [#{idx + 1}/#{total_resources}] Scanning #{resource_name} metafields...")
        scan_resource(resource_name)
      end

      apply_filters!
      generate_report(multi)
      print_summary

      log_info("")
      log_info("✅ #{store['domain']} — scan complete!")
    end

    if multi
      log_info("")
      log_info("🎉 All #{@stores.size} stores scanned!")
    end
  rescue => e
    log_error("Fatal error: #{e.message}")
    log_error(e.backtrace.first(5).join("\n")) if @log_level == "verbose"
    exit 1
  end

  private

  # ---- Store Resolution ----

  def resolve_stores
    if @config["stores"].is_a?(Array) && @config["stores"].any?
      @config["stores"]
    elsif @config["store"].is_a?(Hash)
      [@config["store"]]
    else
      [] # validation will catch this
    end
  end

  def connect_store!(store, store_idx = 0)
    @store = store
    @base_url = "https://#{store['domain']}/admin/api/#{store['api_version'] || '2026-01'}/graphql.json"

    validate_store_credentials!(store, store_idx)
    fetch_access_token!(store)
    test_store_connection!(store)
    check_store_scopes!(store)
  end

  # ---- Token Acquisition ----

  def fetch_access_token!(store)
    domain = store["domain"]
    log_info("🔑 Authenticating with #{domain}...")

    token_url = "https://#{domain}/admin/oauth/access_token"
    uri = URI.parse(token_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request["Accept"] = "application/json"
    request.body = URI.encode_www_form(
      "client_id"     => store["client_id"],
      "client_secret" => store["client_secret"],
      "grant_type"    => "client_credentials"
    )

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      body = begin JSON.parse(response.body) rescue {} end
      error_desc = body["error_description"] || body["error"] || response.body[0..200]

      puts "❌ Authentication failed for #{domain}"
      puts ""
      puts "   #{error_desc}"
      puts ""

      case response.code.to_i
      when 401, 403
        puts "   This usually means:"
        puts "   • The client_id or client_secret is incorrect"
        puts "   • The app was uninstalled from the store"
        puts "   • The client secret was rotated in the Dev Dashboard"
        puts ""
        puts "   To check your credentials:"
        puts "   Dev Dashboard → your app → Settings → Client credentials"
      when 404
        puts "   The store domain might be wrong: #{domain}"
        puts "   Make sure it ends with .myshopify.com"
      else
        puts "   HTTP #{response.code} — check your domain and credentials"
      end
      exit 1
    end

    token_data = JSON.parse(response.body)
    access_token = token_data["access_token"]

    if access_token.nil? || access_token.empty?
      puts "❌ No access token returned for #{domain}"
      puts "   Response: #{response.body[0..200]}"
      exit 1
    end

    @headers = {
      "Content-Type" => "application/json",
      "X-Shopify-Access-Token" => access_token,
    }

    log_info("   ✓ Token acquired (expires in #{token_data['expires_in'] || '?'}s)")

  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    puts "❌ Could not reach #{domain}"
    puts ""
    puts "   #{e.message}"
    puts ""
    puts "   Check that:"
    puts "   • The store domain is correct: #{domain}"
    puts "   • Your network/firewall allows HTTPS connections"
    exit 1
  end

  # ---- Config Loading ----

  def load_config(path)
    unless File.exist?(path)
      puts "❌ Config file not found: #{path}"
      puts ""
      puts "   To get started:"
      puts "   1. Rename the example config:  cp config-example.yml config.yml"
      puts "   2. Open config.yml and fill in your store domain, client_id, and client_secret"
      puts "   3. Run again:  ruby scan_metafields.rb"
      exit 1
    end

    raw = File.read(path)

    # Check for common YAML pitfalls before parsing
    if raw.include?("\t")
      line_num = raw.lines.index { |l| l.include?("\t") }&.+(1)
      puts "❌ Config file contains a tab character (line #{line_num || '?'})"
      puts "   YAML requires spaces for indentation, not tabs."
      puts "   Replace all tabs with spaces in config.yml and try again."
      exit 1
    end

    config = begin
      YAML.safe_load(raw, permitted_classes: [Symbol])
    rescue Psych::SyntaxError => e
      puts "❌ Invalid YAML syntax in config.yml"
      puts ""
      puts "   #{e.message}"
      puts ""
      puts "   Common causes:"
      puts "   • Missing quotes around values with special characters"
      puts "   • Incorrect indentation (must use spaces, not tabs)"
      puts "   • Colons or hashes inside unquoted strings"
      puts ""
      puts "   Tip: Paste your config into https://yamlchecker.com to find the issue."
      exit 1
    end

    unless config.is_a?(Hash)
      puts "❌ Config file is empty or not a valid YAML mapping."
      puts "   Make sure config.yml has the required sections: store, resources, output"
      exit 1
    end

    config
  end

  def validate_global_config!
    errors = []
    warnings = []

    # ── Stores ──
    has_store = @config["store"].is_a?(Hash)
    has_stores = @config["stores"].is_a?(Array) && @config["stores"].any?

    if !has_store && !has_stores
      errors << "Missing store credentials. Your config.yml needs either:\n" \
                "       Single store:\n" \
                "         store:\n" \
                "           domain: \"your-store.myshopify.com\"\n" \
                "           client_id: \"your-client-id\"\n" \
                "           client_secret: \"shpss_...\"\n" \
                "       Multiple stores:\n" \
                "         stores:\n" \
                "           - domain: \"store-one.myshopify.com\"\n" \
                "             client_id: \"...\"\n" \
                "             client_secret: \"shpss_...\""
    end

    if has_store && has_stores
      warnings << "Both 'store' and 'stores' are defined — using 'stores' list (ignoring 'store')"
      @stores = @config["stores"]
    end

    if has_stores
      @config["stores"].each_with_index do |s, i|
        unless s.is_a?(Hash)
          errors << "stores[#{i}] is not a valid mapping — each store needs domain, client_id, and client_secret"
        end
      end
    end

    # ── Section: resources ──
    if @config["resources"].nil?
      warnings << "No 'resources' section found — will scan default resources (products, collections, shop)"
      @config["resources"] = { "product" => true, "collection" => true, "shop" => true }
    elsif !@config["resources"].is_a?(Hash)
      errors << "'resources' must be a mapping of resource names to true/false\n" \
                "       Example:\n" \
                "       resources:\n" \
                "         product: true\n" \
                "         collection: false"
    else
      # Check for unknown resource names
      known = RESOURCE_MAP.keys
      @config["resources"].each do |name, value|
        unless known.include?(name)
          closest = known.min_by { |k| levenshtein(k, name) }
          warnings << "Unknown resource '#{name}' in resources section — did you mean '#{closest}'?\n" \
                      "         Valid resources: #{known.join(', ')}"
        end

        unless [true, false].include?(value)
          errors << "resources.#{name} must be true or false, got: #{value.inspect}\n" \
                    "         Make sure you're using true/false (no quotes), not \"true\"/\"false\""
        end
      end

      # Check that at least one resource is enabled
      enabled = @config["resources"].select { |_, v| v == true }
      if enabled.empty?
        errors << "All resources are disabled — enable at least one resource to scan\n" \
                  "       Set at least one resource to true in the resources section"
      end
    end

    # ── Section: scan ──
    if @config["scan"]
      scan = @config["scan"]

      unless scan.is_a?(Hash)
        errors << "'scan' must be a mapping, not a #{scan.class.name.downcase}"
      else
        method = scan["method"].to_s
        unless %w[bulk graphql].include?(method)
          errors << "scan.method '#{method}' is not valid — must be 'bulk' or 'graphql'\n" \
                    "         • bulk    — recommended for stores with 1000+ resources\n" \
                    "         • graphql — faster for small stores"
        end

        if scan["page_size"] && (!scan["page_size"].is_a?(Integer) || scan["page_size"] < 1 || scan["page_size"] > 250)
          errors << "scan.page_size must be an integer between 1 and 250, got: #{scan['page_size'].inspect}"
        end

        if scan["poll_interval"] && (!scan["poll_interval"].is_a?(Integer) || scan["poll_interval"] < 1)
          warnings << "scan.poll_interval should be a positive integer (seconds) — got: #{scan['poll_interval'].inspect}"
        end

        if scan["max_wait_time"] && (!scan["max_wait_time"].is_a?(Integer) || scan["max_wait_time"] < 10)
          warnings << "scan.max_wait_time of #{scan['max_wait_time']}s seems too low — bulk ops can take minutes on large stores"
        end
      end
    end

    # ── Section: filters ──
    if @config["filters"] && @config["filters"].is_a?(Hash)
      filters = @config["filters"]

      %w[namespaces exclude_namespaces specific_keys].each do |key|
        val = filters[key]
        next if val.nil? || val.is_a?(Array)

        if val.is_a?(String)
          errors << "filters.#{key} must be a YAML list, not a string\n" \
                    "         ✗ #{key}: \"#{val}\"\n" \
                    "         ✓ #{key}: [\"#{val}\"]"
        else
          errors << "filters.#{key} must be a list, got: #{val.class.name.downcase}"
        end
      end

      if filters["specific_keys"].is_a?(Array)
        filters["specific_keys"].each do |key|
          unless key.to_s.include?(".")
            warnings << "filters.specific_keys entry '#{key}' doesn't contain a dot — expected format: 'namespace.key'\n" \
                        "         Example: 'custom.ingredients'"
          end
        end
      end

      if filters["min_total_bytes"] && !filters["min_total_bytes"].is_a?(Integer)
        errors << "filters.min_total_bytes must be an integer, got: #{filters['min_total_bytes'].inspect}"
      end
    end

    # ── Section: output ──
    if @config["output"] && @config["output"].is_a?(Hash)
      output = @config["output"]

      report_type = output["report_type"].to_s
      if !report_type.empty? && !%w[summary detailed].include?(report_type)
        errors << "output.report_type '#{report_type}' is not valid — must be 'summary' or 'detailed'"
      end

      sort_order = output["sort_order"].to_s
      if !sort_order.empty? && !%w[asc desc].include?(sort_order)
        errors << "output.sort_order '#{sort_order}' is not valid — must be 'asc' or 'desc'"
      end

      if output["value_preview_length"] && (!output["value_preview_length"].is_a?(Integer) || output["value_preview_length"] < 0)
        warnings << "output.value_preview_length should be a positive integer"
      end

      if output.key?("split_by_resource") && ![true, false].include?(output["split_by_resource"])
        errors << "output.split_by_resource must be true or false, got: #{output['split_by_resource'].inspect}\n" \
                  "         Make sure you're using true/false (no quotes)"
      end
    end

    # ── Section: progress ──
    if @config["progress"] && @config["progress"].is_a?(Hash)
      style = @config.dig("progress", "style").to_s
      unless style.empty? || %w[spinner bar none].include?(style)
        errors << "progress.style '#{style}' is not valid — must be 'spinner', 'bar', or 'none'\n" \
                  "         • spinner — built-in animation, no gems needed\n" \
                  "         • bar     — fancy progress bar (requires: gem install tty-progressbar)\n" \
                  "         • none    — no animation"
      end

      if style == "bar"
        begin
          require "tty-progressbar"
        rescue LoadError
          warnings << "progress.style is 'bar' but tty-progressbar gem is not installed\n" \
                      "         Install with: gem install tty-progressbar\n" \
                      "         Or switch to progress.style: 'spinner' (no gem needed)"
        end
      end
    end

    # ── Section: thresholds ──
    if @config["thresholds"] && @config["thresholds"].is_a?(Hash)
      thresholds = @config["thresholds"]

      wp = thresholds["warning_percent"]
      if wp && (!wp.is_a?(Numeric) || wp < 0 || wp > 100)
        errors << "thresholds.warning_percent must be a number between 0 and 100, got: #{wp.inspect}"
      end

      fb = thresholds["flag_above_bytes"]
      if fb && (!fb.is_a?(Integer) || fb < 0)
        errors << "thresholds.flag_above_bytes must be a positive integer, got: #{fb.inspect}"
      end

      if thresholds["limits"] && !thresholds["limits"].is_a?(Hash)
        errors << "thresholds.limits must be a mapping of type names to byte limits"
      end
    end

    # ── Section: logging ──
    if @config["logging"] && @config["logging"].is_a?(Hash)
      level = @config.dig("logging", "level").to_s
      unless level.empty? || %w[quiet normal verbose].include?(level)
        warnings << "logging.level '#{level}' is not valid — must be 'quiet', 'normal', or 'verbose'"
        @config["logging"]["level"] = "normal"
      end
    end

    # ── Report results ──
    if warnings.any?
      puts "⚠️  Config warnings:"
      warnings.each_with_index { |w, i| puts "   #{i + 1}. #{w}" }
      puts ""
    end

    if errors.any?
      puts "❌ Config errors (#{errors.size}):"
      puts ""
      errors.each_with_index { |e, i| puts "   #{i + 1}. #{e}" }
      puts ""
      puts "   Please fix these issues in config.yml and run again."
      exit 1
    end
  end

  # ---- Per-Store Validation ----

  def validate_store_credentials!(store, store_idx)
    errors = []
    warnings = []
    label = @stores.size > 1 ? "stores[#{store_idx}]" : "store"

    domain = store["domain"].to_s.strip
    if domain.empty?
      errors << "#{label}.domain is missing — set it to your myshopify.com domain"
    elsif domain.include?("your-store") || domain.include?("example")
      errors << "#{label}.domain is still the placeholder value — replace it with your actual domain\n" \
                "       Example: my-cool-store.myshopify.com"
    elsif domain.start_with?("https://") || domain.start_with?("http://")
      errors << "#{label}.domain should not include https:// — just use the domain\n" \
                "       ✗ https://my-store.myshopify.com\n" \
                "       ✓ my-store.myshopify.com"
    elsif !domain.end_with?(".myshopify.com")
      warnings << "#{label}.domain doesn't end with .myshopify.com — did you mean \"#{domain}.myshopify.com\"?"
    end

    # Client ID
    client_id = store["client_id"].to_s.strip
    if client_id.empty?
      errors << "#{label}.client_id is missing — get it from the Dev Dashboard:\n" \
                "       https://dev.shopify.com → your app → Settings → Client credentials"
    elsif client_id.include?("your") || client_id.include?("xxxx")
      errors << "#{label}.client_id is still the placeholder value — replace with your real Client ID"
    end

    # Client Secret
    client_secret = store["client_secret"].to_s.strip
    if client_secret.empty?
      errors << "#{label}.client_secret is missing — get it from the Dev Dashboard:\n" \
                "       https://dev.shopify.com → your app → Settings → Client credentials"
    elsif client_secret.include?("xxxx") || client_secret.include?("your")
      errors << "#{label}.client_secret is still the placeholder value — replace with your real secret"
    elsif !client_secret.start_with?("shpss_")
      warnings << "#{label}.client_secret doesn't start with 'shpss_' — Shopify app secrets usually do.\n" \
                  "         Make sure you're using the Client Secret, not the Client ID."
    end

    # Warn if someone has the old api_token field
    if store["api_token"]
      warnings << "#{label}.api_token is no longer used — Shopify now requires client_id + client_secret.\n" \
                  "         See: https://dev.shopify.com → create app → Settings → Client credentials.\n" \
                  "         The api_token field will be ignored."
    end

    version = store["api_version"].to_s.strip
    if version.empty?
      warnings << "#{label}.api_version is missing — defaulting to '2026-01'"
      store["api_version"] = "2026-01"
    elsif !version.match?(/\A\d{4}-\d{2}\z/)
      errors << "#{label}.api_version '#{version}' is not valid — expected format: YYYY-MM (e.g., '2026-01')\n" \
                "       See: https://shopify.dev/docs/api/usage/versioning"
    end

    if warnings.any?
      warnings.each { |w| log_warn("   ⚠️  #{w}") }
    end

    if errors.any?
      puts "❌ Credential errors for #{store['domain'] || label}:"
      puts ""
      errors.each_with_index { |e, i| puts "   #{i + 1}. #{e}" }
      puts ""
      puts "   Please fix these issues in config.yml and run again."
      exit 1
    end

    # Rebuild URL with potentially corrected values
    @base_url = "https://#{store['domain']}/admin/api/#{store['api_version']}/graphql.json"
  end

  def test_store_connection!(store)
    label = store["domain"]
    log_info("🔗 Testing API connection to #{label}...")

    begin
      result = graphql_request("{ shop { name plan { displayName } } }")
    rescue => e
      puts "❌ Could not connect to #{label}"
      puts ""
      puts "   #{e.message}"
      puts ""
      puts "   Check that:"
      puts "   • Your store domain is correct: #{label}"
      puts "   • Your app is installed on the store"
      puts "   • The API version '#{store['api_version']}' is supported"
      puts "   • Your network/firewall allows HTTPS connections to Shopify"
      exit 1
    end

    shop = result.dig("data", "shop")
    if shop
      log_info("   Connected to: #{shop['name']} (#{shop.dig('plan', 'displayName')})")
    else
      api_errors = result["errors"]
      if api_errors
        messages = api_errors.map { |e| e["message"] }

        if messages.any? { |m| m.include?("authentication") || m.include?("Unauthorized") }
          puts "❌ API access denied for #{label}"
          puts ""
          puts "   The access token was rejected. This could mean:"
          puts "   • The token expired (tokens last 24 hours) — this shouldn't happen mid-scan"
          puts "   • The app was uninstalled from the store"
          puts "   • The client credentials were rotated"
          puts ""
          puts "   Check your client_id and client_secret in config.yml"
        else
          puts "❌ API error for #{label}: #{messages.join(', ')}"
        end
      else
        puts "❌ Unexpected API response from #{label} — no shop data returned"
      end
      exit 1
    end
    log_info("")
  end

  def check_store_scopes!(store)
    warnings = []
    label = store["domain"]

    enabled_resources.each do |resource_name|
      mapping = RESOURCE_MAP[resource_name]
      next unless mapping && mapping[:query_root]

      test_query = "{ #{mapping[:query_root]}(first: 1) { edges { node { id } } } }"
      test_result = graphql_request(test_query)
      test_errors = test_result["errors"]

      if test_errors&.any? { |e| e["message"].to_s.include?("access") }
        scope_hint = case resource_name
                     when "product", "product_variant", "collection" then "read_products"
                     when "customer", "company", "company_location" then "read_customers"
                     when "order" then "read_orders"
                     when "draft_order" then "read_draft_orders"
                     when "page", "article", "blog" then "read_content"
                     when "location" then "read_locations"
                     else "unknown"
                     end

        warnings << "#{label}: Missing API scope for '#{resource_name}' — add '#{scope_hint}' to the custom app"
        @config["resources"][resource_name] = false
      end
    end

    if warnings.any?
      puts "⚠️  Scope warnings for #{label}:"
      warnings.each_with_index { |w, i| puts "   #{i + 1}. #{w}" }
      remaining = enabled_resources
      if remaining.empty?
        puts ""
        puts "❌ No resources are accessible on #{label} — add the required API scopes and try again."
        exit 1
      end
      puts ""
      puts "   Continuing with accessible resources: #{remaining.join(', ')}"
      puts ""
    end
  end

  # Simple Levenshtein distance for "did you mean?" suggestions
  def levenshtein(a, b)
    m, n = a.length, b.length
    d = Array.new(m + 1) { |i| i }
    (1..n).each do |j|
      prev = d[0]
      d[0] = j
      (1..m).each do |i|
        temp = d[i]
        d[i] = if a[i - 1] == b[j - 1]
                 prev
               else
                 [prev, d[i], d[i - 1]].min + 1
               end
        prev = temp
      end
    end
    d[m]
  end

  def enabled_resources
    resources = @config["resources"] || {}
    resources.select { |_, enabled| enabled }.keys
  end

  def scan_method
    @config.dig("scan", "method") || "bulk"
  end

  # ---- Scanning ----

  def make_progress(label)
    style = @config.dig("progress", "style") || "spinner"
    case style
    when "bar"
      BarProgress.new(label)
    when "none"
      NullProgress.new(label)
    else
      SpinnerProgress.new(label)
    end
  end

  def scan_resource(resource_name)
    mapping = RESOURCE_MAP[resource_name]
    unless mapping
      log_warn("Unknown resource type: #{resource_name}, skipping")
      return
    end

    progress = make_progress(resource_name)

    if resource_name == "shop"
      scan_shop_metafields(progress)
    elsif scan_method == "bulk"
      scan_with_bulk_operation(resource_name, mapping, progress)
    else
      scan_with_graphql(resource_name, mapping, progress)
    end
  rescue => e
    log_error("   Error scanning #{resource_name}: #{e.message}")
    @errors << { resource: resource_name, error: e.message }
  end

  # ---- Shop-level metafields (special case — single resource) ----

  def scan_shop_metafields(progress)
    cursor = nil
    loop do
      query = <<~GQL
        {
          shop {
            metafields(first: 250#{cursor ? ", after: \"#{cursor}\"" : ""}) {
              edges {
                cursor
                node {
                  namespace
                  key
                  type
                  value
                  id
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
      GQL

      result = graphql_request(query)
      edges = result.dig("data", "shop", "metafields", "edges") || []

      edges.each do |edge|
        mf = edge["node"]
        @results << build_result("shop", "shop", "Shop", mf)
        progress.tick
      end

      has_next = result.dig("data", "shop", "metafields", "pageInfo", "hasNextPage")
      break unless has_next
      cursor = edges.last["cursor"]
    end

    count = @results.count { |r| r[:resource_type] == "shop" }
    progress.finish("shop — #{count} metafields found")
  end

  # ---- Paginated GraphQL Scanning ----

  def scan_with_graphql(resource_name, mapping, progress)
    page_size = @config.dig("scan", "page_size") || 50
    mf_per_page = @config.dig("scan", "metafields_per_page") || 50
    query_root = mapping[:query_root]
    name_field = mapping[:name_field]
    resource_cursor = nil
    total_mf = 0
    total_resources = 0

    loop do
      query = <<~GQL
        {
          #{query_root}(first: #{page_size}#{resource_cursor ? ", after: \"#{resource_cursor}\"" : ""}) {
            edges {
              cursor
              node {
                id
                #{name_field}
                metafields(first: #{mf_per_page}) {
                  edges {
                    node {
                      namespace
                      key
                      type
                      value
                      id
                    }
                  }
                  pageInfo { hasNextPage }
                }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      GQL

      result = graphql_request(query)
      edges = result.dig("data", query_root, "edges") || []

      if edges.empty?
        check_for_errors(result, resource_name)
        break
      end

      edges.each do |edge|
        node = edge["node"]
        owner_id = node["id"]
        owner_name = node[name_field] || owner_id
        total_resources += 1

        mf_edges = node.dig("metafields", "edges") || []
        mf_edges.each do |mf_edge|
          mf = mf_edge["node"]
          @results << build_result(resource_name, owner_id, owner_name, mf)
          total_mf += 1
          progress.tick
        end

        # Handle metafield pagination per resource if needed
        if node.dig("metafields", "pageInfo", "hasNextPage")
          extra = fetch_remaining_metafields(resource_name, owner_id, owner_name, mf_per_page, progress)
          total_mf += extra
        end
      end

      has_next = result.dig("data", query_root, "pageInfo", "hasNextPage")
      break unless has_next
      resource_cursor = edges.last["cursor"]

      log_verbose("   ... paged through #{edges.length} #{resource_name}s")
    end

    progress.finish("#{resource_name} — #{total_mf} metafields across #{total_resources} resources")
  end

  def fetch_remaining_metafields(resource_name, owner_id, owner_name, mf_per_page, progress)
    cursor = nil
    count = 0

    loop do
      query = <<~GQL
        {
          node(id: "#{owner_id}") {
            ... on HasMetafields {
              metafields(first: #{mf_per_page}#{cursor ? ", after: \"#{cursor}\"" : ""}) {
                edges {
                  cursor
                  node {
                    namespace
                    key
                    type
                    value
                    id
                  }
                }
                pageInfo { hasNextPage }
              }
            }
          }
        }
      GQL

      result = graphql_request(query)
      edges = result.dig("data", "node", "metafields", "edges") || []
      break if edges.empty?

      edges.each do |edge|
        mf = edge["node"]
        @results << build_result(resource_name, owner_id, owner_name, mf)
        count += 1
        progress.tick
      end

      has_next = result.dig("data", "node", "metafields", "pageInfo", "hasNextPage")
      break unless has_next
      cursor = edges.last["cursor"]
    end

    count
  end

  # ---- Bulk Operations Scanning ----

  def scan_with_bulk_operation(resource_name, mapping, progress)
    query_root = mapping[:query_root]
    name_field = mapping[:name_field]

    bulk_query = <<~GQL
      {
        #{query_root} {
          edges {
            node {
              id
              #{name_field}
              metafields {
                edges {
                  node {
                    namespace
                    key
                    type
                    value
                    id
                  }
                }
              }
            }
          }
        }
      }
    GQL

    # Submit bulk operation
    mutation = <<~GQL
      mutation {
        bulkOperationRunQuery(query: """#{bulk_query}""") {
          bulkOperation {
            id
            status
          }
          userErrors {
            field
            message
          }
        }
      }
    GQL

    result = graphql_request(mutation)
    user_errors = result.dig("data", "bulkOperationRunQuery", "userErrors") || []

    if user_errors.any?
      error_msg = user_errors.map { |e| e["message"] }.join(", ")
      # If a bulk op is already running, fall back to graphql
      if error_msg.include?("already in progress")
        log_warn("   Bulk operation already running — falling back to GraphQL for #{resource_name}")
        scan_with_graphql(resource_name, mapping, progress)
        return
      end
      raise "Bulk operation failed: #{error_msg}"
    end

    op_id = result.dig("data", "bulkOperationRunQuery", "bulkOperation", "id")
    progress.update_label("#{resource_name} (bulk operation queued)")

    # Poll for completion with a waiting spinner
    poll_interval = @config.dig("scan", "poll_interval") || 3
    max_wait = @config.dig("scan", "max_wait_time") || 600
    elapsed = 0
    wait_spinner = SpinnerProgress.new("#{resource_name} — waiting for Shopify")

    loop do
      sleep(poll_interval)
      elapsed += poll_interval
      wait_spinner.tick

      if elapsed > max_wait
        wait_spinner.finish("timed out after #{max_wait}s")
        raise "Bulk operation timed out after #{max_wait}s"
      end

      status_query = <<~GQL
        {
          node(id: "#{op_id}") {
            ... on BulkOperation {
              status
              errorCode
              url
              objectCount
            }
          }
        }
      GQL

      status_result = graphql_request(status_query)
      op = status_result.dig("data", "node")

      case op["status"]
      when "COMPLETED"
        wait_spinner.finish("#{resource_name} — bulk operation completed (#{op['objectCount']} objects)")
        if op["url"]
          parse_bulk_results(resource_name, name_field, op["url"], progress)
        else
          progress.finish("#{resource_name} — no metafields found")
        end
        return
      when "FAILED"
        wait_spinner.finish("failed")
        raise "Bulk operation failed: #{op['errorCode']}"
      when "CANCELED", "CANCELLED"
        wait_spinner.finish("cancelled")
        raise "Bulk operation was cancelled"
      else
        wait_spinner.update_label("#{resource_name} — #{op['status'].downcase} (#{elapsed}s)")
      end
    end
  end

  def parse_bulk_results(resource_name, name_field, url, progress)
    uri = URI.parse(url)
    response = Net::HTTP.get(uri)
    count = 0
    current_owner = nil

    progress.update_label("#{resource_name} — parsing results")

    response.each_line do |line|
      obj = JSON.parse(line.strip)

      if obj.key?(name_field) || (obj.key?("id") && !obj.key?("namespace"))
        # This is a parent resource
        current_owner = {
          id: obj["id"],
          name: obj[name_field] || obj["id"],
        }
      elsif obj.key?("namespace") && obj.key?("key")
        # This is a metafield
        owner_id = current_owner ? current_owner[:id] : obj["__parentId"] || "unknown"
        owner_name = current_owner ? current_owner[:name] : "unknown"

        @results << build_result(resource_name, owner_id, owner_name, obj)
        count += 1
        progress.tick
      end
    end

    progress.finish("#{resource_name} — #{count} metafields parsed")
  end

  # ---- Result Building ----

  def build_result(resource_type, owner_id, owner_name, metafield)
    value = metafield["value"].to_s
    byte_size = value.bytesize

    # Check against thresholds
    mf_type = metafield["type"].to_s
    limit = type_limit(mf_type)
    usage_pct = limit > 0 ? ((byte_size.to_f / limit) * 100).round(2) : 0
    warning_pct = @config.dig("thresholds", "warning_percent") || 80
    flag_bytes = @config.dig("thresholds", "flag_above_bytes") || 50_000

    {
      resource_type:  resource_type,
      owner_id:       owner_id,
      owner_name:     owner_name,
      namespace:      metafield["namespace"],
      key:            metafield["key"],
      metafield_type: mf_type,
      metafield_id:   metafield["id"],
      value_bytes:    byte_size,
      type_limit:     limit,
      usage_percent:  usage_pct,
      warning:        usage_pct >= warning_pct ? "⚠️ #{usage_pct}% of limit" : "",
      flagged:        byte_size >= flag_bytes,
      value_preview:  value[0..(@config.dig("output", "value_preview_length") || 100)],
    }
  end

  def type_limit(mf_type)
    limits = @config.dig("thresholds", "limits") || {}
    normalized = mf_type.to_s.downcase.gsub(".", "_")
    limits[normalized] || limits["default"] || 524_288
  end

  # ---- Filtering ----

  def apply_filters!
    filters = @config["filters"] || {}

    namespaces = filters["namespaces"] || []
    if namespaces.any?
      @results.select! { |r| namespaces.include?(r[:namespace]) }
    end

    excludes = filters["exclude_namespaces"] || []
    if excludes.any?
      @results.reject! { |r| excludes.include?(r[:namespace]) }
    end

    specific_keys = filters["specific_keys"] || []
    if specific_keys.any?
      @results.select! { |r| specific_keys.include?("#{r[:namespace]}.#{r[:key]}") }
    end

    min_bytes = filters["min_total_bytes"] || 0
    if min_bytes > 0
      @results.select! { |r| r[:value_bytes] >= min_bytes }
    end
  end

  # ---- Report Generation ----

  def generate_report(multi_store = false)
    output_cfg = @config["output"] || {}
    report_type = output_cfg["report_type"] || "summary"
    split = output_cfg["split_by_resource"] == true

    dir = output_cfg["directory"] || "./results"
    FileUtils.mkdir_p(dir)

    if split
      generate_split_reports(dir, report_type, output_cfg)
    else
      generate_combined_report(dir, report_type, output_cfg)
    end
  end

  def generate_combined_report(dir, report_type, output_cfg)
    filename = build_filename(output_cfg["filename"] || "{store}_metafields_{timestamp}.csv")
    filepath = File.join(dir, filename)

    if report_type == "summary"
      write_summary_csv(filepath, @results)
    else
      write_detailed_csv(filepath, @results)
    end

    log_info("")
    log_info("📄 Report saved to: #{filepath}")
  end

  def generate_split_reports(dir, report_type, output_cfg)
    by_resource = @results.group_by { |r| r[:resource_type] }
    files = []

    by_resource.each do |resource_type, results|
      filename = build_filename("{store}_metafields_#{resource_type}_{timestamp}.csv")
      filepath = File.join(dir, filename)

      if report_type == "summary"
        write_summary_csv(filepath, results)
      else
        write_detailed_csv(filepath, results)
      end

      files << { resource: resource_type, path: filepath, count: results.size }
    end

    log_info("")
    log_info("📄 Reports saved to: #{dir}/")
    files.each do |f|
      log_info("   #{f[:resource].ljust(20)} → #{File.basename(f[:path])} (#{f[:count]} metafields)")
    end
  end

  def write_summary_csv(filepath, results)
    # Group by resource_type + namespace + key
    grouped = results.group_by { |r| [r[:resource_type], r[:namespace], r[:key], r[:metafield_type]] }

    rows = grouped.map do |(resource_type, namespace, key, mf_type), entries|
      bytes = entries.map { |e| e[:value_bytes] }
      {
        resource_type: resource_type,
        namespace:     namespace,
        key:           key,
        metafield_type: mf_type,
        count:         entries.size,
        total_bytes:   bytes.sum,
        avg_bytes:     (bytes.sum.to_f / bytes.size).round(0),
        max_bytes:     bytes.max,
        min_bytes:     bytes.min,
        type_limit:    entries.first[:type_limit],
        max_usage_pct: entries.map { |e| e[:usage_percent] }.max,
        warnings:      entries.count { |e| !e[:warning].empty? },
      }
    end

    # Sort
    sort_col = (@config.dig("output", "sort_by") || "total_bytes").to_sym
    sort_dir = @config.dig("output", "sort_order") || "desc"
    rows.sort_by! { |r| r[sort_col] || 0 }
    rows.reverse! if sort_dir == "desc"

    headers = %i[resource_type namespace key metafield_type count total_bytes avg_bytes max_bytes min_bytes type_limit max_usage_pct warnings]

    CSV.open(filepath, "w") do |csv|
      csv << headers.map(&:to_s)
      rows.each { |row| csv << headers.map { |h| row[h] } }

      if @config.dig("output", "include_totals")
        csv << []
        csv << [
          "TOTAL", "", "", "",
          rows.sum { |r| r[:count] },
          rows.sum { |r| r[:total_bytes] },
          "", "", "", "", "",
          rows.sum { |r| r[:warnings] },
        ]
      end
    end
  end

  def write_detailed_csv(filepath, results)
    sort_col = (@config.dig("output", "sort_by") || "value_bytes").to_sym
    sort_dir = @config.dig("output", "sort_order") || "desc"
    sorted = results.sort_by { |r| r[sort_col] || 0 }
    sorted.reverse! if sort_dir == "desc"

    headers = %i[resource_type owner_id owner_name namespace key metafield_type value_bytes type_limit usage_percent warning]
    headers << :value_preview if @config.dig("output", "include_value_preview")

    CSV.open(filepath, "w") do |csv|
      csv << headers.map(&:to_s)
      sorted.each { |row| csv << headers.map { |h| row[h] } }

      if @config.dig("output", "include_totals")
        csv << []
        csv << [
          "TOTAL", "", "", "", "", "",
          sorted.sum { |r| r[:value_bytes] },
        ]
      end
    end
  end

  def build_filename(template)
    store_slug = @store["domain"].to_s.gsub(/\.myshopify\.com$/, "").gsub(/[^a-zA-Z0-9_-]/, "_")
    now = Time.now

    template
      .gsub("{store}", store_slug)
      .gsub("{date}", now.strftime("%Y-%m-%d"))
      .gsub("{timestamp}", now.strftime("%Y%m%d_%H%M%S"))
  end

  # ---- Summary ----

  def print_summary
    return if @results.empty?

    total_bytes = @results.sum { |r| r[:value_bytes] }
    total_mf = @results.size
    by_type = @results.group_by { |r| r[:resource_type] }

    log_info("")
    log_info("📊 Summary")
    log_info("=" * 50)
    log_info("   Total metafields scanned: #{total_mf}")
    log_info("   Total size: #{format_bytes(total_bytes)}")
    log_info("")

    by_type.each do |type, entries|
      type_bytes = entries.sum { |e| e[:value_bytes] }
      log_info("   #{type.ljust(20)} #{entries.size.to_s.rjust(6)} metafields  #{format_bytes(type_bytes).rjust(12)}")
    end

    warnings = @results.count { |r| !r[:warning].empty? }
    if warnings > 0
      log_info("")
      log_info("   ⚠️  #{warnings} metafields approaching size limits")
    end

    if @errors.any?
      log_info("")
      log_info("   ❌ #{@errors.size} resource types had errors:")
      @errors.each { |e| log_info("      - #{e[:resource]}: #{e[:error]}") }
    end
  end

  # ---- GraphQL Client ----

  def graphql_request(query)
    uri = URI.parse(@base_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.path, @headers)
    request.body = { query: query }.to_json

    log_verbose("GraphQL request: #{query[0..100]}...")

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code}: #{response.body[0..200]}"
    end

    # Handle rate limiting
    cost = response["X-Shopify-Shop-Api-Call-Limit"]
    log_verbose("   API cost: #{cost}") if cost

    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    log_warn("Request timeout, retrying in 5s...")
    sleep 5
    retry
  end

  def check_for_errors(result, context)
    errors = result["errors"]
    return unless errors

    errors.each do |err|
      msg = err["message"]
      if msg.include?("access") || msg.include?("scope")
        log_warn("   ⚠️  Missing API scope for #{context} — skipping (#{msg})")
      else
        log_warn("   ⚠️  #{context}: #{msg}")
      end
    end
  end

  # ---- Helpers ----

  def format_bytes(bytes)
    if bytes >= 1_073_741_824
      "#{(bytes / 1_073_741_824.0).round(2)} GB"
    elsif bytes >= 1_048_576
      "#{(bytes / 1_048_576.0).round(2)} MB"
    elsif bytes >= 1024
      "#{(bytes / 1024.0).round(2)} KB"
    else
      "#{bytes} B"
    end
  end

  def log_info(msg)
    puts msg unless @log_level == "quiet"
  end

  def log_warn(msg)
    puts msg
  end

  def log_error(msg)
    $stderr.puts msg
  end

  def log_verbose(msg)
    puts "   [debug] #{msg}" if @log_level == "verbose"
  end
end

# ---- CLI ----

config_path = "./config.yml"

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scan_metafields.rb [options]"

  opts.on("-c", "--config PATH", "Path to config file (default: ./config.yml)") do |path|
    config_path = path
  end

  opts.on("-v", "--version", "Show version") do
    puts "Shopify Metafield Scanner v#{ShopifyMetafieldScanner::VERSION}"
    exit
  end

  opts.on("-h", "--help", "Show help") do
    puts opts
    puts ""
    puts "Quick Start:"
    puts "  1. Rename config-example.yml → config.yml"
    puts "  2. Add your store domain, client_id, and client_secret"
    puts "  3. Run: ruby scan_metafields.rb"
    exit
  end
end.parse!

scanner = ShopifyMetafieldScanner.new(config_path)
scanner.run
