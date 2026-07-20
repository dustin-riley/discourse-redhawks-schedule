# frozen_string_literal: true

class RedhawksRecruitController < ::ApplicationController
  # Load-bearing, as on the schedule controller: anonymous visitors are most of
  # a public fan forum's readers and must get cards.
  requires_login false
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, raise: false

  def show
    slug = params[:slug].to_s
    return render_missing unless ::RedhawksSchedule::RecruitSource.valid_slug?(slug)

    entry = read_store(slug)

    if entry.nil?
      entry = fetch_inline(slug)
      return render_missing if entry.nil?
    elsif stale?(entry)
      # Serve the stale copy now and refresh behind the reader. Nobody waits on
      # 247, and the card self-heals within a day.
      ::Jobs.enqueue(:refresh_redhawks_recruit, slug: slug)
    end

    response.headers["Cache-Control"] = "public, max-age=900"
    render json: entry
  end

  private

  def read_store(slug)
    PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule.recruit_store_key(slug))
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] store read failed: #{e.class}: #{e.message}")
    nil
  end

  def stale?(entry)
    fetched_at = entry["fetched_at"]
    return true if fetched_at.blank?

    Time.now.utc - Time.iso8601(fetched_at) >= ::RedhawksSchedule::RECRUIT_TTL
  rescue ArgumentError
    true
  end

  # Nothing cached: the reader would otherwise get no card at all, so pay the
  # fetch once. Every later view is served from the store.
  def fetch_inline(slug)
    url = ::RedhawksSchedule::RecruitSource.url_for(slug)
    return nil if url.nil?

    body = FinalDestination::HTTP.get(URI(url))
    return nil if body.blank?

    recruit = ::RedhawksSchedule::RecruitParser.parse(body)
    return nil if recruit.nil?

    entry = { "fetched_at" => Time.now.utc.iso8601, "recruit" => recruit }
    PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule.recruit_store_key(slug), entry)
    entry
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] inline fetch failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # 404 with an empty body. The component treats any non-200 as "leave the
  # existing onebox alone", so this is the silent-failure path.
  def render_missing
    render json: {}, status: :not_found
  end
end
