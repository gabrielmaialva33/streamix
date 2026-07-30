defmodule StreamixWeb.E2E.LoginPersistenceTest do
  @moduledoc """
  Exercises the login form across the CI browser matrix with an
  iPhone-sized viewport.

  Password managers replace both credential fields and dispatch input events
  together. The form must not patch itself and reset the persistent-login
  checkbox while those events are being processed.
  """

  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :webkit
                       end)

  use PhoenixTest.Playwright.Case,
    async: false,
    browser: @playwright_browser,
    browser_pool: false

  use StreamixWeb, :verified_routes

  @moduletag :playwright

  @mobile_context_opts [
                         viewport: %{width: 390, height: 844},
                         device_scale_factor: 3.0,
                         service_workers: "block"
                       ] ++
                         if(@playwright_browser == :firefox,
                           do: [],
                           else: [is_mobile: true]
                         )

  @tag browser_context_opts: @mobile_context_opts
  test "keeps persistent login selected while the password manager fills credentials", %{
    conn: session
  } do
    session
    |> visit(~p"/login")
    |> assert_has("body .phx-connected #user_remember_me:checked")
    |> assert_autofill_safe_login()
  end

  defp assert_autofill_safe_login(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      async () => {
        const setValue = (element, value) => {
          const setter = Object.getOwnPropertyDescriptor(
            HTMLInputElement.prototype,
            "value"
          ).set;

          setter.call(element, value);
          element.dispatchEvent(new InputEvent("input", {
            bubbles: true,
            data: value,
            inputType: "insertReplacementText"
          }));
          element.dispatchEvent(new Event("change", {bubbles: true}));
        };

        const email = document.querySelector("#user_email");
        const password = document.querySelector("#user_password");
        setValue(email, "saved@example.com");
        setValue(password, "saved-password");

        await new Promise((resolve) => setTimeout(resolve, 250));

        const checkbox = document.querySelector("#user_remember_me");
        const label = checkbox.closest("label");
        const checkboxRect = checkbox.getBoundingClientRect();
        const labelRect = label.getBoundingClientRect();

        return {
          checked: checkbox.checked,
          formHasLiveChange: checkbox.form.hasAttribute("phx-change"),
          emailAutocomplete: email.getAttribute("autocomplete"),
          passwordAutocomplete: password.getAttribute("autocomplete"),
          checkboxSize: {
            width: checkboxRect.width,
            height: checkboxRect.height
          },
          touchTargetHeight: labelRect.height
        };
      }
      """,
      [is_function: true],
      fn state ->
        assert state["checked"], inspect(state)
        refute state["formHasLiveChange"], inspect(state)
        assert state["emailAutocomplete"] == "username", inspect(state)
        assert state["passwordAutocomplete"] == "current-password", inspect(state)
        assert state["checkboxSize"]["width"] >= 20, inspect(state)
        assert state["checkboxSize"]["height"] >= 20, inspect(state)
        assert state["touchTargetHeight"] >= 44, inspect(state)
      end
    )
  end
end
