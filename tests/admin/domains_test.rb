# frozen_string_literal: true

require "/opt/postal/app/config/environment"
require "minitest/autorun"
require "tempfile"
require "stringio"

# Only DNS transport is substituted. Real Rails routing, Postal model callbacks,
# RSA keys, persistence, ownership verifier and HasDNSChecks run in the image.
class TestDNS
  attr_accessor :mode, :domain

  def txt(name)
    raise Resolv::ResolvError, "test DNS unavailable" if mode == :unavailable
    return [] if mode == :missing
    return [domain.dkim_record] if name == "#{domain.dkim_record_name}.#{domain.name}"

    values = [domain.spf_record]
    values << domain.dns_verification_string unless mode == :no_ownership
    values
  end

  def cname(_name)
    mode == :missing ? [] : [Postal::Config.dns.return_path_domain]
  end

  def mx(_name)
    # Existing mailbox provider is deliberately not moved to Postal.
    [[10, "mailbox.example.net"]]
  end
end

class AdminDomainsTest < Minitest::Test
  def setup
    @old_env = ENV.to_h.slice("POSTAL_ADMIN_TOKEN", "POSTAL_ADMIN_TOKEN_FILE")
    ENV.delete("POSTAL_ADMIN_TOKEN_FILE")
    # Ephemeral test credentials exist only in this Ruby process, never fixtures,
    # shell arguments, test output or CI secrets. Deployment uses vault/seal.
    @token = SecureRandom.hex(32)
    ENV["POSTAL_ADMIN_TOKEN"] = @token
    @log = StringIO.new
    @previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
    @suffix = SecureRandom.hex(6)
    owner = User.create!(first_name: "Test", last_name: "Owner",
                         email_address: "#{@suffix}@example.net", password: SecureRandom.hex(32))
    @org = Organization.create!(name: "Test", permalink: "test-#{@suffix}", owner: owner)
    @other = Organization.create!(name: "Other", permalink: "other-#{@suffix}", owner: owner)
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host! Postal::Config.postal.web_hostname
    @dns = TestDNS.new
    @dns.mode = :missing
    Domain.define_method(:resolver) { Thread.current[:imajin_test_dns] }
    Thread.current[:imajin_test_dns] = @dns
  end

  def teardown
    refute @log.string.include?(@token), "admin credential must not appear in logs"
    Rails.logger = @previous_logger
    ENV.delete("POSTAL_ADMIN_TOKEN")
    ENV.delete("POSTAL_ADMIN_TOKEN_FILE")
    @old_env.each { |key, value| ENV[key] = value }
    Thread.current[:imajin_test_dns] = nil
  end

  def request(method, path = "/imajin/v1/domains", body: nil, token: @token)
    headers = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    @session.public_send(method, path, params: body&.to_json, headers: headers)
    @response = @session.response
    @json = JSON.parse(@response.body) if @response.media_type == "application/json"
    @response.status
  end

  def payload(name = "owner.example.net")
    { organization: @org.permalink, name: name }
  end

  def path(action = nil, org: @org)
    "/imajin/v1/domains/owner.example.net#{action}?organization=#{org.permalink}"
  end

  def create_domain
    assert_equal 201, request(:post, body: payload)
    @dns.domain = @org.domains.find_by!(name: "owner.example.net")
  end

  def test_all_routes_require_exact_runtime_bearer
    [[:post, "/imajin/v1/domains"], [:get, path], [:post, path("/check")]].each do |method, url|
      [nil, SecureRandom.hex(32), ""].each do |credential|
        assert_equal 401, request(method, url, body: payload, token: credential)
        assert_equal "unauthorized", @json["error"]
        assert_equal "Bearer", @response.headers["WWW-Authenticate"]
      end
    end
    assert_equal 0, @org.domains.count
    ENV.delete("POSTAL_ADMIN_TOKEN")
    assert_equal 401, request(:post, body: payload)
    ENV["POSTAL_ADMIN_TOKEN"] = ""
    assert_equal 401, request(:post, body: payload)
  end

  def test_file_token_and_fail_closed_configuration
    Tempfile.create("postal-test-token") do |file|
      file.chmod(0o600)
      file.write(@token + "\n")
      file.flush
      ENV["POSTAL_ADMIN_TOKEN_FILE"] = file.path
      ENV["POSTAL_ADMIN_TOKEN"] = SecureRandom.hex(32)
      assert_equal 201, request(:post, body: payload)
      file.truncate(0)
      assert_equal 401, request(:post, body: payload)
      file.rewind
      file.write(" " * 8193)
      file.flush
      assert_equal 401, request(:post, body: payload)
    end
    ENV["POSTAL_ADMIN_TOKEN_FILE"] = "/missing/imajin-token"
    assert_equal 401, request(:post, body: payload)
  end

  def test_create_read_retry_and_exact_records
    domain = create_domain
    assert_equal "DNS", domain.verification_method
    refute domain.verified?
    assert domain.dkim_private_key.present?
    first = @json
    assert_equal 200, request(:post, body: payload("OWNER.EXAMPLE.NET"))
    assert_equal first, @json
    assert_equal 1, @org.domains.count
    assert_equal 200, request(:get, path)
    assert_equal first, @json
    assert_equal "pending", @json["state"]
    assert_equal "no-store", @response.headers["Cache-Control"]
    records = @json["records"].index_by { |r| r["kind"] }
    assert_equal domain.dns_verification_string, records["ownership"]["value"]
    assert_equal domain.spf_record, records["spf"]["value"]
    assert_equal "include:#{Postal::Config.dns.spf_include}", records["spf"]["include"]
    assert_equal "#{domain.dkim_record_name}.#{domain.name}", records["dkim"]["name"]
    assert_equal domain.dkim_record, records["dkim"]["value"]
    assert_equal domain.return_path_domain, records["return_path"]["name"]
    assert_equal Postal::Config.dns.return_path_domain, records["return_path"]["value"]
    assert_equal Postal::Config.dns.mx_records, @json["records"].select { |r| r["kind"] == "mx" }.map { |r| r["value"] }
    refute records["mx"]["required"]
    assert_equal 10, records["mx"]["priority"]
    refute @response.body.include?(domain.dkim_private_key)
    refute @response.body.include?(@token)
    assert_equal 0, domain.routes.count
    @dns.mode = :unavailable
    assert_equal 200, request(:get, path)
  end

  def test_check_uses_postal_verifiers_and_persists_state
    domain = create_domain
    assert_equal 200, request(:post, path("/check"))
    assert_equal "pending", @json["state"]
    assert_equal "Missing", @json["records"].find { |r| r["kind"] == "spf" }["status"]
    assert @json["dns_checked_at"]
    @dns.mode = :no_ownership
    assert_equal 200, request(:post, path("/check"))
    assert @json["dns_ok"]
    refute @json["ownership_verified"]
    assert_equal "pending", @json["state"]
    @dns.mode = :valid
    assert_equal 200, request(:post, path("/check"))
    assert_equal "verified", @json["state"]
    assert @json["ownership_verified"]
    assert domain.reload.verified?
    assert_equal 200, request(:get, path)
    assert_equal "verified", @json["state"]
    # Regression after verification must not be reported as ready.
    @dns.mode = :missing
    assert_equal 200, request(:post, path("/check"))
    assert_equal "pending", @json["state"]
  end

  def test_dns_failure_is_sanitized_and_does_not_verify
    domain = create_domain
    @dns.mode = :unavailable
    assert_equal 503, request(:post, path("/check"))
    assert_equal({ "error" => "dns_unavailable" }, @json)
    refute domain.reload.verified?
  end

  def test_organization_scope_and_lifecycle
    create_domain
    assert_equal 404, request(:get, path(org: @other))
    assert_equal 404, request(:post, path("/check", org: @other))
    assert_equal 201, request(:post, body: payload.merge(organization: @other.permalink))
    assert_equal 1, @other.domains.count
    @org.update!(suspended_at: Time.now)
    assert_equal 409, request(:post, body: payload)
    assert_equal 409, request(:get, path)
    assert_equal 409, request(:post, path("/check"))
    @org.soft_destroy
    assert_equal 404, request(:get, path)
    assert_equal 404, request(:post, body: payload)
    assert_equal 404, request(:post, path("/check"))
    assert_equal 404, request(:post, body: payload.merge(organization: "unknown"))
  end

  def test_validation_rejects_invalid_names_and_organizations
    [nil, {}, [], "", "localhost", "-bad.example", "bad-.example", "bad..example",
     "bad_example.net", "bad.example.", "*.example.net", "https://example.net",
     "a" * 64 + ".net", (["a" * 63] * 4).join(".")].each do |name|
      assert_equal 422, request(:post, body: payload(name))
      assert_equal "invalid_request", @json["error"]
    end
    [nil, {}, [], "", "Bad", "-bad", "bad-", "a" * 256].each do |org|
      assert_equal 422, request(:post, body: payload.merge(organization: org))
    end
    assert_equal 0, @org.domains.count
    assert_equal 422, request(:get, "/imajin/v1/domains/owner.example.net")
    assert_equal 422, request(:post, "/imajin/v1/domains/owner.example.net/check")
  end

  def test_cannot_mass_assign_verification_or_owner
    create_domain
    assert_equal 200, request(:post, body: payload.merge(
      verified_at: Time.now, owner_id: @other.id, verification_method: "Email",
      dkim_private_key: "ignored", spf_status: "OK"
    ))
    domain = @org.domains.find_by!(name: "owner.example.net")
    refute domain.verified?
    assert_equal "DNS", domain.verification_method
    assert_equal @org, domain.owner
    assert_nil domain.spf_status
  end

  def test_no_delete_or_update_surface
    domain = create_domain
    [:delete, :patch, :put].each do |method|
      assert_equal 404, request(method, path)
    end
    assert domain.reload.persisted?
  end

  def test_malformed_json_and_unknown_domain
    @session.post("/imajin/v1/domains", params: "{",
                  headers: { "CONTENT_TYPE" => "application/json",
                             "Authorization" => "Bearer #{@token}" })
    assert_equal 400, @session.response.status
    assert_equal 404, request(:get, path)
    assert_equal 404, request(:post, path("/check"))
  end

  def test_auth_scheme_and_query_token_cannot_bypass_authentication
    ["Basic", "Bearer", "Bearer wrong extra"].each do |header|
      @session.post("/imajin/v1/domains", params: payload.to_json,
                    headers: { "CONTENT_TYPE" => "application/json", "Authorization" => header })
      assert_equal 401, @session.response.status
      assert_nil @session.response.headers["Set-Cookie"]
    end
    assert_equal 401, request(:post, body: payload.merge(postal_admin_token: @token), token: nil)
    ENV["POSTAL_ADMIN_TOKEN"] = SecureRandom.hex(32)
    assert_equal 401, request(:post, body: payload)
  end

  def test_concurrent_retries_create_one_domain
    responses = Queue.new
    threads = 3.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.host! Postal::Config.postal.web_hostname
          session.post("/imajin/v1/domains", params: payload.to_json,
                       headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{@token}" })
          responses << session.response.status
        end
      end
    end
    threads.each(&:join)
    assert_equal [200, 200, 201], 3.times.map { responses.pop }.sort
    assert_equal 1, @org.domains.count
  end
end
