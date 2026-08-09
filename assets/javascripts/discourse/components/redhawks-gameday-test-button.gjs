import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import DiscourseURL from "discourse/lib/url";
import { i18n } from "discourse-i18n";

// Sits in the header of the plugin's own admin config page, next to the
// "Redhawks schedule" title. The endpoint it calls posts a real topic into a
// real category, so this is a one-click action with a visible consequence --
// hence routing straight to the created topic rather than a toast the admin
// has to act on.
export default class RedhawksGamedayTestButton extends Component {
  @service dialog;

  @tracked posting = false;

  @action
  async postTestThread() {
    this.posting = true;

    try {
      const result = await ajax(
        "/admin/plugins/discourse-redhawks-schedule/gameday-test.json",
        { type: "POST" }
      );
      DiscourseURL.routeTo(result.topic_url);
    } catch (e) {
      // The endpoint answers a refusal with { reason }, not Discourse's usual
      // { errors: [...] }, so popupAjaxError would surface nothing useful.
      this.dialog.alert(
        e.jqXHR?.responseJSON?.reason ||
          i18n("redhawks_schedule.gameday_test.failed")
      );
    } finally {
      this.posting = false;
    }
  }

  <template>
    <DButton
      class="btn-default redhawks-gameday-test"
      @action={{this.postTestThread}}
      @label="redhawks_schedule.gameday_test.label"
      @title="redhawks_schedule.gameday_test.title"
      @disabled={{this.posting}}
    />
  </template>
}
