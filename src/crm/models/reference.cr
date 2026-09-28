# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Étape du pipeline (ADR-009 D3), paramétrable par dossier : nom, ordre,
  # probabilité par défaut (0 à 100). `kind` : `open` (étape de travail),
  # `won` ou `lost` (étapes de clôture fixes, une de chaque). `code` : étape
  # initiale (`discovery`, `qualification`, `proposal`, `negotiation`, `won`,
  # `lost`), dont le libellé est traduit tant que `name` est vide ; vide
  # pour une étape ajoutée par le dossier. Interne.
  class Stage < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 32, blank: true, default: ""
    field :name, :string, max_size: 100, blank: true, default: ""
    field :position, :int, default: 0
    field :probability, :int, default: 0
    field :kind, :string, max_size: 8, default: "open"
    field :active, :bool, default: true

    with_timestamp_fields
  end

  # Motif de perte d'une opportunité (ADR-009 D3), paramétrable. Même
  # principe de `code` et `name` que les étapes. Interne.
  class LossReason < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 32, blank: true, default: ""
    field :name, :string, max_size: 100, blank: true, default: ""
    field :position, :int, default: 0
    field :active, :bool, default: true

    with_timestamp_fields
  end

  # Origine d'un contact ou d'une opportunité (salon, site,
  # recommandation…), paramétrable (ADR-009 D2, D3). Interne.
  class Source < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 32, blank: true, default: ""
    field :name, :string, max_size: 100, blank: true, default: ""
    field :position, :int, default: 0
    field :active, :bool, default: true

    with_timestamp_fields
  end
end
