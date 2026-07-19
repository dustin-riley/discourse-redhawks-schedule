# frozen_string_literal: true

class RedhawksScheduleController < ::ApplicationController
  requires_login false
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, raise: false

  def index
    # A database hiccup must degrade to an absent sidebar, not a 500. This is
    # the only remaining path that could render a broken section rather than
    # no section at all.
    payload =
      begin
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::STORE_KEY)
      rescue StandardError => e
        Rails.logger.warn("[redhawks-schedule] store read failed: #{e.class}: #{e.message}")
        nil
      end
    payload ||= { "generated_at" => nil, "events" => [] }

    response.headers["Cache-Control"] = "public, max-age=900"
    render json: payload
  end
end
