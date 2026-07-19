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

## Net effect on the plan

One correction: the outlet name in Task 11 becomes `after-sidebar-sections`.
Everything else in Tasks 6, 7 and 11 stands as written.
