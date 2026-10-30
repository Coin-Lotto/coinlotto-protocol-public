import { expect } from "chai";
import { UNEMITTED, missingFunctionEmissions, missingProductionEvents } from "../scripts/checkEventCoverage";

describe("production event coverage", function () {
  it("asserts every reachable function and event pair", function () {
    const missing = missingFunctionEmissions();
    expect(missing, missing.join("\n")).to.deep.equal([]);
  });

  it("asserts every event the production contracts emit", function () {
    const missing = missingProductionEvents();
    expect(missing, `missing assertions: ${missing.join(", ")}`).to.deep.equal([]);
  });

  it("documents events that no reachable production path emits", function () {
    expect(UNEMITTED.map((item) => item.event)).to.deep.equal(["RoleAdminChanged", "EtherRefundFailed"]);
    for (const item of UNEMITTED) {
      expect(item.reason.length).to.be.greaterThan(20);
    }
  });
});
