# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Pipeline des opportunités (ADR-009 D3) : changement d'étape historisé
  # (qui, quand, de quelle étape à quelle étape), probabilité reprise de
  # l'étape, clôture datée, motif obligatoire pour « Perdue ». Interne ;
  # appelé dans la transaction de la commande ou de l'événement.
  module Pipeline
    alias FieldError = Partiduo::Api::FieldError

    # Erreurs d'un changement d'étape, sans rien enregistrer.
    def self.errors(row : Opportunity, stage : Stage?, input : Api::MoveInput) : Array(FieldError)
      errors = [] of FieldError
      if stage.nil? || !stage.active
        errors << Records.error("stage_id", "opportunity.stage_id.invalid", {"value" => input.stage_id.to_s})
        return errors
      end
      if stage.kind == "lost"
        reason = input.loss_reason_id.try { |id| LossReason.filter(id: id).first }
        if input.loss_reason_id.nil?
          errors << Records.error("loss_reason_id", "opportunity.loss_reason_id.blank")
        elsif reason.nil? || !reason.active
          errors << Records.error("loss_reason_id", "opportunity.loss_reason_id.unknown", {"value" => input.loss_reason_id.to_s})
        end
      end
      if input.loss_note.strip.size > 2000
        errors << Records.error("loss_note", "opportunity.loss_note.too_long", {"max" => "2000"})
      end
      errors
    end

    # Passe l'opportunité à l'étape `stage` (sans effet si elle y est déjà) :
    # probabilité de l'étape, clôture datée pour « Gagnée » et « Perdue »,
    # motif de perte gardé seulement pour « Perdue », trace dans l'historique.
    def self.move!(row : Opportunity, stage : Stage, user_id : Int64?, cause : String = "",
                   loss_reason_id : Int64? = nil, loss_note : String = "") : Bool
      from = row.stage_id.try(&.to_i64)
      return false if from == stage.id
      row.stage_id = stage.id
      row.probability = stage.probability || 0
      if stage.kind == "open"
        row.closed_at = nil
      else
        row.closed_at = Time.utc
      end
      if stage.kind == "lost"
        row.loss_reason_id = loss_reason_id
        row.loss_note = loss_note.strip
      else
        row.loss_reason_id = nil
        row.loss_note = ""
      end
      row.save!
      record!(row.id!.to_i64, from, stage.id!.to_i64, user_id, cause)
      true
    end

    def self.record!(opportunity_id : Int64, from : Int64?, to : Int64, user_id : Int64?, cause : String) : Nil
      StageChange.create!(opportunity_id: opportunity_id, from_stage_id: from, to_stage_id: to, user_id: user_id,
        cause: cause, created_at: Time.utc)
    end

    # Étape « Proposition » (valeur initiale `proposal`) si elle est active.
    def self.proposal_stage : Stage?
      Stage.filter(code: "proposal", active: true).first
    end

    # L'opportunité est-elle à une étape de travail antérieure à `stage` ?
    def self.before?(row : Opportunity, stage : Stage) : Bool
      current = Records.stage!(row.stage_id!.to_i64)
      current.kind == "open" && (current.position || 0).to_i64 < (stage.position || 0).to_i64
    end
  end
end
