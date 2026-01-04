import Button from "./Button";
import { render } from "../../test-utils";
import { describe, expect, it } from "vitest";

describe("Button", () => {
  it("renders", () => {
    console.log("RUNNING TEST!!");
    const tree = render(() => <Button title="Hello" />);
    expect(tree).toMatchSnapshot();
  });
});
