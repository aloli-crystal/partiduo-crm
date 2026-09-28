# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Opportunité (ADR-009 D3) : intitulé, organisation, contact principal,
  # montant estimé HT, probabilité, clôture prévue, responsable
  # (utilisateur du dossier), étape, origine ; motif et commentaire de
  # perte ; date de clôture (étape « Gagnée » ou « Perdue »). Interne.
  class Opportunity < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :title, :string, max_size: 200
    field :organization_id, :big_int, index: true
    field :contact_id, :big_int, blank: true, null: true, index: true
    field :amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
    field :probability, :int, default: 0
    field :expected_close_on, :date, blank: true, null: true
    field :owner_id, :big_int, blank: true, null: true, index: true
    field :stage_id, :big_int, index: true
    field :source_id, :big_int, blank: true, null: true
    field :loss_reason_id, :big_int, blank: true, null: true
    field :loss_note, :text, blank: true, default: ""
    field :closed_at, :date_time, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Changement d'étape d'une opportunité (ADR-009 D3) : qui, quand, de
  # quelle étape à quelle étape ; `cause` : vide pour un déplacement à la
  # main, `created`, `quote_created` ou `quote_accepted`. Journal en ajout
  # seul (déclencheur de la migration). Interne.
  class StageChange < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :opportunity_id, :big_int, index: true
    field :from_stage_id, :big_int, blank: true, null: true
    field :to_stage_id, :big_int
    field :user_id, :big_int, blank: true, null: true
    field :cause, :string, max_size: 32, blank: true, default: ""
    field :created_at, :date_time
  end

  # Devis ou facture de la Facturation rattaché à une opportunité (ADR-009
  # D5) : identifiant du document lu par `Partiduo::Api::Invoicing`, sans
  # clé étrangère (un brouillon de devis peut être supprimé, D-CRM-003).
  # `kind` : `quote` ou `invoice`. Interne.
  class DocumentLink < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :opportunity_id, :big_int, index: true
    field :document_id, :big_int, unique: true
    field :kind, :string, max_size: 16
    field :created_by_id, :big_int, blank: true, null: true
    field :created_at, :date_time
  end

  # Activité à échéance (ADR-009 D4) : appel, rendez-vous, courriel, tâche
  # ou note ; échéance, date et durée, responsable, compte rendu, fait ou à
  # faire ; rattachée à une organisation, un contact et / ou une
  # opportunité. Interne.
  class Activity < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 16
    field :subject, :string, max_size: 200
    field :due_on, :date, index: true
    field :starts_at, :date_time, blank: true, null: true
    field :duration_minutes, :int, blank: true, null: true
    field :owner_id, :big_int, blank: true, null: true, index: true
    field :report, :text, blank: true, default: ""
    field :done, :bool, default: false
    field :done_at, :date_time, blank: true, null: true
    field :organization_id, :big_int, blank: true, null: true, index: true
    field :contact_id, :big_int, blank: true, null: true, index: true
    field :opportunity_id, :big_int, blank: true, null: true, index: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
