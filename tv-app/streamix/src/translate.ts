import * as i18n from "@solid-primitives/i18n";
import en_dict from "../public/assets/lang/en.json";
import { createResource, createSignal } from "solid-js";

const [locale, setLocale] = createSignal("en");
// setLocale("es"); will switch to spanish

async function fetchDictionary(locale) {
  return fetch(`assets/lang/${locale}.json`)
    .then(response => response.json())
    .catch(error => {
      console.log(error);
    });
}

const [dict] = createResource(locale, fetchDictionary, {
  initialValue: en_dict,
});

const $t = i18n.translator(dict);

export { $t, locale, setLocale };
