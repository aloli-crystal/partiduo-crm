# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Tuile « Commercial » des tableaux de bord du dossier (ADR-009 D6) :
    # pipeline pondéré, opportunités ouvertes, activités en retard, lus par
    # `Crm::Api.tile` (rien si l'extension est inactive ou l'acteur sans
    # droit). Elle paraît sur le tableau de bord complet comme sur ceux du
    # mode simplifié (micro-entreprise, profession libérale).
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        late = view.late_activities
        PartiduoUi::Dashboard::Tile.new(Crm::CODE, I18n.t("crm_ui.tile.label"), fmt.amount(view.weighted_amount),
          sub: I18n.t("crm_ui.tile.sub", count: view.open_count),
          alert: late.zero? ? nil : I18n.t("crm_ui.tile.late", count: late), url: Ui.url("pipeline"))
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active.
PartiduoUi::Extensions.tile Crm::CODE do |actor, fmt|
  Crm::Ui::Tile.for(actor, fmt).try { |tile| [tile] } || [] of PartiduoUi::Dashboard::Tile
end
