# frozen_string_literal: true

require "digest"

module Imajin
  # Deliberately independent of Postal's browser session/admin bypass.
  class DomainsController < ActionController::API
    skip_before_action :set_browser_id, :validate_auth_session
    skip_around_action :touch_auth_session
    before_action :authenticate
    before_action :validate_input
    before_action :load_organization

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "not_found" }, status: :not_found
    end
    rescue_from ActiveRecord::RecordInvalid do
      render json: { error: "invalid_domain" }, status: :unprocessable_entity
    end
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: { error: "invalid_json" }, status: :bad_request
    end
    rescue_from Resolv::ResolvError, Timeout::Error, DNSResolver::LocalResolversUnavailableError do
      render json: { error: "dns_unavailable" }, status: :service_unavailable
    end

    def create
      created = false
      # Postal has application-level uniqueness, not a DB unique index. Lock the
      # existing organization to serialize API retries, including across workers.
      domain = @organization.with_lock do
        @organization.domains.find_by(name: @name) || begin
          created = true
          @organization.domains.create!(name: @name, verification_method: "DNS")
        end
      end
      render json: representation(domain), status: created ? :created : :ok
    end

    def show
      render json: representation(find_domain)
    end

    def check
      domain = find_domain
      domain.with_lock do
        domain.verify_with_dns unless domain.verified?
        domain.check_dns(:manual)
      end
      render json: representation(domain)
    end

    private

    def authenticate
      response.headers["Cache-Control"] = "no-store"
      expected = runtime_token
      supplied = request.authorization.to_s.match(/\ABearer ([^\s]+)\z/i)&.[](1)
      valid = expected.present? && supplied.present? &&
              ActiveSupport::SecurityUtils.secure_compare(
                Digest::SHA256.digest(expected), Digest::SHA256.digest(supplied)
              )
      return if valid

      response.headers["WWW-Authenticate"] = "Bearer"
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def runtime_token
      # File takes precedence; unreadable/empty files fail closed (no fallback).
      if ENV["POSTAL_ADMIN_TOKEN_FILE"].present?
        value = File.read(ENV.fetch("POSTAL_ADMIN_TOKEN_FILE"), 8193).to_s
        value.bytesize <= 8192 ? value.strip : nil
      else
        ENV["POSTAL_ADMIN_TOKEN"].to_s
      end
    rescue SystemCallError, IOError
      nil
    end

    def validate_input
      org = params[:organization]
      name = params[:name]
      valid_org = org.is_a?(String) && org.bytesize <= 255 &&
                  org.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      @name = name.downcase if name.is_a?(String)
      valid_name = @name && @name.bytesize <= 253 &&
                   @name.split(".", -1).size >= 2 &&
                   @name.split(".", -1).all? do |label|
                     label.bytesize <= 63 && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
                   end
      return if valid_org && valid_name

      render json: { error: "invalid_request" }, status: :unprocessable_entity
    end

    def load_organization
      @organization = Organization.present.find_by!(permalink: params[:organization])
      return unless @organization.suspended?

      render json: { error: "organization_suspended" }, status: :conflict
    end

    def find_domain
      @organization.domains.find_by!(name: @name)
    end

    def record(kind, type, name, value, status, required:, error: nil, **extra)
      { kind: kind, type: type, name: name, value: value, required: required,
        status: status || "Unchecked", error: error }.merge(extra)
    end

    def representation(domain)
      records = [
        record("ownership", "TXT", domain.name, domain.dns_verification_string,
               domain.verified? ? "OK" : "Pending", required: true),
        record("spf", "TXT", domain.name, domain.spf_record, domain.spf_status,
               required: true, error: domain.spf_error,
               include: "include:#{Postal::Config.dns.spf_include}"),
        record("dkim", "TXT", "#{domain.dkim_record_name}.#{domain.name}", domain.dkim_record,
               domain.dkim_status, required: true, error: domain.dkim_error),
        record("return_path", "CNAME", domain.return_path_domain, Postal::Config.dns.return_path_domain,
               domain.return_path_status, required: false, error: domain.return_path_error)
      ]
      Postal::Config.dns.mx_records.each do |host|
        records << record("mx", "MX", domain.name, host, domain.mx_status,
                          required: false, error: domain.mx_error, priority: 10)
      end
      {
        organization: @organization.permalink, name: domain.name, id: domain.uuid,
        state: domain.verified? && domain.dns_ok? ? "verified" : "pending",
        ownership_verified: domain.verified?, dns_ok: domain.dns_ok?,
        verified_at: domain.verified_at&.iso8601,
        dns_checked_at: domain.dns_checked_at&.iso8601, records: records
      }
    end
  end
end
