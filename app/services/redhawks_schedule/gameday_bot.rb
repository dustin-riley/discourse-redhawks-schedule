# frozen_string_literal: true

module ::RedhawksSchedule
  # The account gameday topics are posted as.
  #
  # Identity is the STORED USER ID, not the username. Resolving by username
  # each run would create a second account the first time anyone renames the
  # bot in the admin UI, orphaning every existing thread's author. With the id
  # stored, Swoop Bot can be renamed, re-avatared and given a bio freely.
  #
  # Core's own bots were both rejected: `system` (-1) has an unguarded
  # User.seed fixture, so seed-fu resets its username on every db:migrate, and
  # it attributes all staff and automation notices; `discobot` (-2) routes any
  # reply to its own posts into the new-user tutorial, which would answer fans
  # in every game thread.
  class GamedayBot
    DISPLAY_NAME = "Swoop Bot"
    # Must not normalize onto a real account's address. `normalize_emails` is
    # on, so Gmail plus-addressing collapses: rileymdustin+bot@gmail.com
    # normalizes to rileymdustin@gmail.com, which the site owner already holds,
    # and User.create! fails with "Email has already been taken". The bot never
    # receives mail -- build_user sets both email levels to never -- so this
    # only has to be unique, and an address on our own domain is.
    EMAIL = "swoop-bot@miamihawktalk.fans"

    def self.resolve
      stored_id = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::BOT_ID_KEY)

      if stored_id
        user = User.find_by(id: stored_id)
        if user.nil?
          # Deliberately not recreated: a vanished bot account is a thing to
          # look at, not to paper over with a fresh one.
          Rails.logger.warn(
            "[redhawks-schedule] gameday bot user ##{stored_id} no longer exists; posting nothing",
          )
        end
        return user
      end

      create_bot
    end

    def self.create_bot
      username = SiteSetting.redhawks_gameday_poster_username
      username = "swoop_bot" if username.blank?

      existing = User.find_by_username(username)
      if existing
        # Adopt an existing account at this username only if its email is
        # ours. That still self-heals the case where a previous run's
        # build_user succeeded but the PluginStore.set below raised before
        # recording the id -- the next run finds that orphan by username and
        # picks it back up. It refuses to adopt anyone else: username is free
        # text an admin can type, and without this check a real member who
        # already holds that username would be silently annexed as the
        # poster for every gameday topic. Do not weaken this back to a bare
        # username lookup.
        if existing.email == EMAIL
          user = existing
        else
          Rails.logger.warn(
            "[redhawks-schedule] redhawks_gameday_poster_username (#{username}) belongs to " \
              "an existing account that is not the gameday bot; change the site setting to an " \
              "unused username and try again",
          )
          return nil
        end
      else
        user = build_user(username)
      end

      PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::BOT_ID_KEY, user.id)
      user
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] could not create the gameday bot: #{e.class}: #{e.message}")
      nil
    end

    def self.build_user(username)
      user =
        User.create!(
          username: UserNameSuggester.suggest(username),
          name: DISPLAY_NAME,
          email: EMAIL,
          password: SecureRandom.hex(32),
          active: true,
          approved: true,
          trust_level: TrustLevel[4],
        )

      user.email_tokens.update_all(confirmed: true)
      user.user_option&.update!(
        email_messages_level: UserOption.email_level_types[:never],
        email_level: UserOption.email_level_types[:never],
      )
      user
    end
  end
end
