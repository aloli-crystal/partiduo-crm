# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Organisation suivie par la relation client (ADR-009 D2) : entreprise,
  # administration ou particulier. *Prospect* tant que `card_id` est nul ;
  # *client* une fois rattachée à une fiche client du cœur (`card_id`, lue
  # par `Partiduo::Api::Cards`, sans clé étrangère : D-CRM-003). `nature` :
  # celle d'un client du cœur (`business`, `individual`, `public`). Interne.
  class Organization < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :name, :string, max_size: 200
    field :nature, :string, max_size: 16, default: "business"
    field :siren, :string, max_size: 9, blank: true, default: ""
    field :vat_number, :string, max_size: 32, blank: true, default: ""
    field :email, :string, max_size: 254, blank: true, default: ""
    field :phone, :string, max_size: 32, blank: true, default: ""
    field :website, :string, max_size: 200, blank: true, default: ""
    field :line1, :string, max_size: 200, blank: true, default: ""
    field :postcode, :string, max_size: 16, blank: true, default: ""
    field :city, :string, max_size: 100, blank: true, default: ""
    field :country_code, :string, max_size: 2, blank: true, default: ""
    field :card_id, :big_int, blank: true, null: true, unique: true
    field :source_id, :big_int, blank: true, null: true
    field :owner_id, :big_int, blank: true, null: true
    field :notes, :text, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Personne suivie (ADR-009 D2), rattachée à une organisation ou isolée.
  # Consentement (RGPD) : origine (`source_id`), base légale de la
  # prospection (`legal_basis`, datée `legal_basis_on`), opposition datée
  # (`opposed_at`). Interne.
  class Contact < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :organization_id, :big_int, blank: true, null: true, index: true
    field :civility, :string, max_size: 8, blank: true, default: ""
    field :first_name, :string, max_size: 100, blank: true, default: ""
    field :last_name, :string, max_size: 100
    field :job_title, :string, max_size: 100, blank: true, default: ""
    field :email, :string, max_size: 254, blank: true, default: ""
    field :phone, :string, max_size: 32, blank: true, default: ""
    field :mobile, :string, max_size: 32, blank: true, default: ""
    field :source_id, :big_int, blank: true, null: true
    field :legal_basis, :string, max_size: 24, blank: true, default: ""
    field :legal_basis_on, :date, blank: true, null: true
    field :opposed_at, :date_time, blank: true, null: true
    field :opposition_note, :text, blank: true, default: ""
    field :notes, :text, blank: true, default: ""

    with_timestamp_fields
  end
end
