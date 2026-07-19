# frozen_string_literal: true

class RedhawksScheduleController < ::ApplicationController
  requires_login false
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, raise: false

  def index
    payload =
      PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::STORE_KEY) ||
        { "generated_at" => nil, "events" => [] }

    response.headers["Cache-Control"] = "public, max-age=900"
    render json: payload
  end
end
