{
  pweb.capabilities - capability policy implementations (Phase 2 / CAP-2).

  TAllowAllCapabilityPolicy is the EXPLICIT, DELIBERATE allow-all
  policy ratified for Phase 2: ICapabilityPolicy is in the invocation
  path from the very first bridge so that Phase 8 swaps the policy
  implementation, never the plumbing (security-model.md; kernel.md).

  It is not a placeholder to be bypassed: every invocation from every
  caller traverses IsAllowed on a worker thread before the bridge is
  reached, exactly as the restrictive Phase 8 policy will be traversed.
  Do not special-case or skip the policy call because this
  implementation happens to return True.

  RTL-only: no mORMot, no platform identifier, no policy-source format.
}
unit pweb.capabilities;

{$mode ObjFPC}{$H+}

interface

uses
  pweb.rpc.intf;

type
  /// Phase-2 explicit allow-all ICapabilityPolicy.
  // - permits every syntactically canonical method for every principal;
  //   deliberate and documented, NOT a fail-open accident: the
  //   scheduler still treats a policy exception as deny + internal_error
  // - Phase 8 replaces this implementation with the effective-set
  //   evaluation (AppMaximum intersect Principal intersect Window
  //   intersect RuntimeGrants) behind the same interface
  // - stateless, therefore safe for concurrent worker-thread calls
  TAllowAllCapabilityPolicy = class(TInterfacedObject, ICapabilityPolicy)
  public
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
  end;

implementation

function TAllowAllCapabilityPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
begin
  Result := True; // explicit allow-all - see the unit header
end;

end.
