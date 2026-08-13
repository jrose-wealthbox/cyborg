# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgActionsSubjectKeyTest < Minitest::Test
  def setup
    @identity = {
      identity_version: 1,
      action_kind: " Review ",
      subject_type: " GitHub_Pull_Request ",
      subject_id: " Node-42 ",
      owner_identity: " Me@Example.COM ",
      target_identity: " Acme/Cyborg#42 "
    }
  end

  def test_evidence_changes_do_not_change_subject_key
    first = Cyborg::Actions::SubjectKey.call(**@identity, evidence_ids: %w[e1])
    second = Cyborg::Actions::SubjectKey.call(**@identity, evidence_ids: %w[e1 e2])

    assert_equal first, second
    assert_match(/\A[0-9a-f]{64}\z/, first)
  end

  def test_identity_normalization_is_deterministic_and_does_not_mutate_inputs
    normalized = Cyborg::Actions::SubjectKey.call(**@identity)
    equivalent = Cyborg::Actions::SubjectKey.call(
      identity_version: 1, action_kind: "review", subject_type: "github_pull_request",
      subject_id: "node-42", owner_identity: "me@example.com", target_identity: "acme/cyborg#42"
    )

    assert_equal normalized, equivalent
    assert_equal " Review ", @identity.fetch(:action_kind)
  end

  def test_identity_version_and_canonical_tuple_fields_change_key
    refute_equal(
      Cyborg::Actions::SubjectKey.call(**@identity),
      Cyborg::Actions::SubjectKey.call(**@identity.merge(identity_version: 2))
    )
    refute_equal(
      Cyborg::Actions::SubjectKey.call(**@identity),
      Cyborg::Actions::SubjectKey.call(**@identity.merge(subject_id: "node-43"))
    )
  end
end
