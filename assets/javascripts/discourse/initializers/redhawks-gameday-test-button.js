import { registerPluginHeaderActionComponent } from "discourse/lib/admin-plugin-header-actions";
import RedhawksGamedayTestButton from "../components/redhawks-gameday-test-button";

// The id is the plugin's dasherized name -- what
// AdminPluginConfigPage looks the component up by.
export default {
  name: "redhawks-gameday-test-button",

  initialize() {
    registerPluginHeaderActionComponent(
      "discourse-redhawks-schedule",
      RedhawksGamedayTestButton
    );
  },
};
