# API verification — Discourse (current `main`)

Verified: 2026-07-19, by reading `discourse/discourse` source directly rather
than grepping the running container. The container greps in the plan's Task 1
were written against the old tree layout and no longer resolve — see finding 0.

## 0. The frontend tree moved

`app/assets/javascripts/discourse/app/…` no longer exists. Frontend source now
lives under:

```
frontend/discourse/app/
```

This is why the plan's Task 1 Step 1 grep returned "No such file or directory".
Any future path-based discovery must start from `frontend/discourse/app/`.

## 1. Sidebar plugin outlet — PLAN WAS WRONG

The plan assumed `below-sidebar-sections`. **That outlet does not exist**; a
GitHub code search across the whole repo returns zero hits.

The outlets that actually exist, in
`frontend/discourse/app/components/sidebar.gjs`:

```
<nav id="d-sidebar" class="sidebar-container">
  {{#if this.showSwitchPanelButtonsOnTop}}<SwitchPanelButtons …/>{{/if}}

  <PluginOutlet @name="before-sidebar-sections" />      <!-- exists -->

  {{#if this.sidebarState.showMainPanel}}
    <Sections … />
  {{else}}
    <ApiPanels … />
  {{/if}}

  <PluginOutlet @name="after-sidebar-sections" />       <!-- exists — USE THIS -->

  {{#unless this.showSwitchPanelButtonsOnTop}}<SwitchPanelButtons …/>{{/unless}}
  <Footer />
</nav>
```

**Use `after-sidebar-sections`.** It renders inside the sidebar `<nav>`, below
the navigation sections and above the switch-panel buttons and footer — exactly
where an "Upcoming Games" block belongs.

Also available but not chosen: `before-sidebar-sections` (above the nav
sections, too prominent) and `sidebar-footer-actions` in
`components/sidebar/footer.gjs` (footer action row, styled for buttons).

### The approved row design survives

`api.addSidebarSection` remains strictly **link-based** — one line of text per
link plus a prefix and suffix — and cannot express the approved two-line row.
That was the risk the plan flagged. It does not bite us, because
`after-sidebar-sections` is a normal plugin outlet and accepts an arbitrary
Glimmer component through `api.renderInOutlet`. No fallback to the text-only
layout is needed.

(For reference, had we gone the `addSidebarSection` route: `prefixType: "image"`
does render `<img src={{prefixValue}} class="prefix-image">`, so logos would
have worked; the two-line text is what it cannot do. Links also expose
`suffixComponent`/`suffixArgs` for arbitrary components in the suffix slot.)

## 2. apiInitializer — plan was correct

Exported from `frontend/discourse/app/lib/api.js`, so the import is:

```js
import { apiInitializer } from "discourse/lib/api";
```

The version-string first argument is **optional and ignored**:

```js
export function apiInitializer(apiCodeCallback, opts) {
  if (typeof arguments[0] === "string") {
    // Old path. First argument is the version string. Silently ignore.
    [, apiCodeCallback, opts] = arguments;
  }
```

Passing no version string is correct and current.

## 3. FinalDestination::HTTP — plan was correct

`lib/final_destination/http.rb`:

```ruby
class FinalDestination::HTTP < Net::HTTP
  def connect
    ...SSRF protection...
```

It subclasses `Net::HTTP` and overrides only `connect`, so the inherited
`Net::HTTP.get(URI(url))` class method routes through the SSRF-protected
`connect` and returns the response **body as a String**. It does not raise on
4xx/5xx — which is precisely why the job's `body.include?("<rss")` guard is
load-bearing rather than belt-and-braces.

## 4. Controller filters — plan was correct, plus one new filter that is harmless

`app/controllers/application_controller.rb` still defines all three filters the
controller skips: `check_xhr`, `preload_json`, `redirect_to_login_if_required`.

There is a newer filter, `block_if_requires_login`, which the plan does not
skip. It does not need skipping:

```ruby
def block_if_requires_login
  if arg = self.class.requires_login_arg   # `requires_login false` => false => falsy
    ...
    ensure_logged_in if check
  end
end
```

`requires_login false` sets `@requires_login_arg = false`, so the guard is
falsy and the filter is a no-op. Anonymous access works as designed.

Note also `redirect_to_login_if_required` early-returns for JSON API requests,
but our endpoint is skipping it outright anyway, which covers `login_required`
sites for ordinary browser fetches.

## 5. Admin-only controllers — verified 2026-08-09

Read against `discourse/discourse` `main` on GitHub (not the container — the
container runs an older image until the Task 5 rebuild pulls `latest`, and
`main` is what that rebuild will actually deploy).

### Base class enforces admin, not staff

`app/controllers/admin/admin_controller.rb`:

```
https://raw.githubusercontent.com/discourse/discourse/main/app/controllers/admin/admin_controller.rb
```

```ruby
class Admin::AdminController < ApplicationController
  requires_login
  before_action :ensure_admin

  def index
    render body: nil
  end
end
```

It calls `before_action :ensure_admin`, not `ensure_staff`. In
`app/controllers/application_controller.rb`:

```ruby
def ensure_staff
  raise Discourse::InvalidAccess.new unless current_user && current_user.staff?
end

def ensure_admin
  raise Discourse::InvalidAccess.new unless current_user && current_user.admin?
end
```

These are two different methods with two different checks
(`current_user.staff?` vs `current_user.admin?`). `Admin::AdminController`
uses `ensure_admin`, so **it is admin-only; moderators are rejected.** The
design's assumption holds — no correction needed here.

`check_xhr` is not skipped (`Admin::AdminController` doesn't touch it), but it
doesn't matter for a `.json`-suffixed route: `check_xhr` only raises when the
request is neither XHR nor JSON-format (`app/controllers/application_controller.rb`
line 735: `raise ApplicationController::RenderEmpty.new if !request.format&.json? && !request.xhr?`),
and `POST /redhawks-gameday-test.json` is JSON-format by construction.

### What an unauthorised caller gets: 403 in both cases, not 404

Traced the full filter chain in `application_controller.rb`:

- `requires_login` (no args) sets `@requires_login_arg = {}` — truthy — so
  `block_if_requires_login` calls `ensure_logged_in` for every action:

  ```ruby
  def ensure_logged_in
    raise Discourse::NotLoggedIn.new if current_user.blank?
  end
  ```

- `rescue_from Discourse::NotLoggedIn` branches on request shape:

  ```ruby
  rescue_from Discourse::NotLoggedIn do |e|
    if (request.format && request.format.json?) || request.xhr? || !request.get?
      rescue_discourse_actions(:not_logged_in, 403, include_ember: true)
    else
      rescue_discourse_actions(:not_found, 404)
    end
  end
  ```

  `POST /redhawks-gameday-test.json` is both JSON-format and non-GET, so the
  first branch applies: **an anonymous caller gets 403, not 404 or a
  redirect.** (The 404 branch is for anonymous *browser navigation* to an
  HTML admin page, which this endpoint isn't.)

- A logged-in non-admin (ordinary user or moderator) passes `ensure_logged_in`
  but fails `ensure_admin`, raising `Discourse::InvalidAccess`, which is
  rescued the same way:

  ```ruby
  rescue_from Discourse::InvalidAccess do |e|
    cookies.delete(e.opts[:delete_cookie]) if e.opts[:delete_cookie].present?
    rescue_discourse_actions(:invalid_access, 403, include_ember: true, ...)
  end
  ```

  **An ordinary logged-in user (or a moderator) also gets 403.** Both
  unauthorised cases — anonymous and non-admin-logged-in — resolve to the
  same status, 403, for this endpoint. Task 4's spec can assert 403 for both
  without expecting them to differ.

### `requires_plugin` exists and takes a plugin-name string

`app/controllers/application_controller.rb`:

```ruby
def self.requires_plugin(plugin_name)
  before_action do
    if plugin = Discourse.plugins_by_name[plugin_name]
      raise PluginDisabled.new if !plugin.enabled?
    elsif Rails.env.test?
      raise "Required plugin '#{plugin_name}' not found. The string passed to requires_plugin should match the plugin's name at the top of plugin.rb"
    else
      Rails.logger.warn("Required plugin '#{plugin_name}' not found")
    end
  end
end
```

It takes a plain string that must match the `# name:` header in `plugin.rb`.
This repo's `plugin.rb` already defines that as a constant:

```ruby
module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
```

matching `# name: discourse-redhawks-schedule` at the top of the same file.
Both bundled-plugin examples below call `requires_plugin PLUGIN_NAME` in
their admin controllers, so `RedhawksGamedayTestController` should call
`requires_plugin ::RedhawksSchedule::PLUGIN_NAME`.

### Route namespacing — PLAN WAS WRONG: not top-level

Checked two bundled plugins' real admin controllers and routes.

`plugins/chat/app/controllers/chat/admin/incoming_webhooks_controller.rb`:

```ruby
module Chat
  module Admin
    class IncomingWebhooksController < ::Admin::AdminController
      requires_plugin PLUGIN_NAME
```

routed in `plugins/chat/plugin.rb`:

```ruby
Discourse::Application.routes.append do
  mount ::Chat::Engine, at: "/chat"

  get "/admin/plugins/chat/hooks" => "chat/admin/incoming_webhooks#index",
      :constraints => StaffConstraint.new
  post "/admin/plugins/chat/hooks" => "chat/admin/incoming_webhooks#create",
       :constraints => StaffConstraint.new
  ...
```

`plugins/discourse-ai/app/controllers/discourse_ai/admin/ai_artifacts_controller.rb`:

```ruby
module DiscourseAi
  module Admin
    class AiArtifactsController < ::Admin::AdminController
      requires_plugin PLUGIN_NAME
```

routed in `plugins/discourse-ai/config/routes.rb`:

```ruby
scope "/admin/plugins/discourse-ai", constraints: AdminConstraint.new do
  ...
  resources :ai_artifacts,
            only: %i[index show create update destroy],
            path: "ai-artifacts",
            controller: "discourse_ai/admin/ai_artifacts",
            ...
```

Both examples: (1) subclass `::Admin::AdminController` — confirming the
design's base-class assumption — and (2) route under `/admin/plugins/<slug>/…`,
never at the top level, and additionally wrap the routes in a route-level
`constraints:` guard (`StaffConstraint`/`AdminConstraint`) on top of the
controller's own `ensure_admin` filter. No top-level (non-`/admin/`) admin
controller route was found in either plugin.

Authorisation itself does not depend on the URL prefix — `ensure_admin` runs
regardless of path — so a top-level route would still *enforce* admin-only
access correctly. But it would be the only admin controller in the Discourse
codebase routed that way, based on the two examples checked: every real
example is namespaced under `/admin/plugins/`. The task brief calls that a
correction to carry forward, not a footnote, so: **the route must not be
`post "/redhawks-gameday-test"`.** It should be namespaced, e.g.
`post "/admin/plugins/discourse-redhawks-schedule/gameday-test" =>
"redhawks_gameday_test#create", :format => :json`, inside a
`scope "/admin/plugins/discourse-redhawks-schedule", constraints:
AdminConstraint.new do … end` block (or an equivalent `:constraints =>` on the
single route, matching the `chat` plugin's per-route style) — Task 4 owns the
exact path segment and constraint style, but the `/admin/plugins/` prefix is
not optional based on what was found.

**Decision:** `RedhawksGamedayTestController` subclasses `::Admin::AdminController`
(confirmed — enforces `ensure_admin`, i.e. admin, not staff) and **does** call
`requires_plugin ::RedhawksSchedule::PLUGIN_NAME`. The route **is** namespaced
under `/admin/plugins/discourse-redhawks-schedule/`, because both bundled
examples checked (`chat`, `discourse-ai`) route their `::Admin::AdminController`
subclasses that way and neither has a top-level admin controller route.
Task 4's assumed route line, `post "/redhawks-gameday-test" =>
"redhawks_gameday_test#create", :format => :json`, is corrected by this
finding — it must move under `/admin/plugins/discourse-redhawks-schedule/`.
Unauthorised-caller statuses: **403** for an anonymous POST to the `.json`
route (not 404 — that branch is for anonymous HTML navigation only), and
**403** for an ordinary logged-in non-admin user too, both traced from
`application_controller.rb`'s `rescue_from` handlers rather than guessed.

Caveat: this reads `main` as of 2026-08-09. The deployed container runs an
older image until Task 5's rebuild pulls `latest` — the right reference for
code being deployed by that rebuild, but if `main` changes again before then,
the rebuild will pick up whatever is current at that time, not what's quoted
here.

## Net effect on the plan

One correction: the outlet name in Task 11 becomes `after-sidebar-sections`.
Everything else in Tasks 6, 7 and 11 stands as written.
