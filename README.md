# AWS

**Daniel Assarélius** · MOV25 · Amazon Web Services · Novatrix AB

Repo: [github.com/82danass/aws](https://github.com/82danass/aws)

## Uppgifter

### [v42 — Compute och kom igång](v42/README.md)
- [x] Sätt upp kursrepo på GitHub (README med namn, kurs, veckorubrik)
- [x] Provisionera en EC2-instans med Amazon Linux, key pair och security group
- [x] Konfigurera värdmiljön: anslut via SSH och installera en webbserver
- [x] Driftsätt webbsidan om Novatrix på instansens publika IP
- [x] Verifiera och dokumentera
- [x] Kostnadskontroll: månadsbudget i AWS Budgets med larm på faktisk och prognostiserad kostnad

### [v43 — IAM och identitet](v43/README.md)
- [x] Skapa avsnitt för v43 och uppdatera README
- [x] Skapa IAM-användare och grupper för Novatrix roller, t.ex. drift och utveckling
- [x] Skapa och koppla policies enligt least privilege
- [x] Skapa en IAM-roll som låter en AWS-tjänst nå en annan
- [x] Verifiera och dokumentera

### [v44 — Nätverk och säkerhet](v44/README.md)
- [ ] Skapa avsnitt för v44 och uppdatera README
- [ ] Bygg ett VPC med publika och privata subnät, route tables och internet gateway
- [ ] Säkra trafiken med security groups och NACL:er
- [ ] Placera webbservern i ett publikt subnät och förbered ett privat subnät för databasen
- [ ] Verifiera och dokumentera nätverket med en skiss

### [v45 — Storage och databas](v45/README.md)
- [ ] Skapa avsnitt för v45 och uppdatera README
- [ ] Provisionera en databas i RDS med MariaDB/MySQL i ett privat subnät
- [ ] Sätt upp delad lagring i EFS för WordPress-filerna
- [ ] Skapa en S3-bucket för databasens backup, med livscykelregel på 14 dagar och automatisk backup i RDS
- [ ] Installera WordPress och koppla den mot databasen och den delade lagringen
- [ ] Säkra åtkomsten i lager
- [ ] Verifiera och dokumentera

### [v46 — IaC med CloudFormation](v46/README.md)
- [ ] Skapa avsnitt för v46 med templates versionshanterade i repot
- [ ] Skriv CloudFormation-template(s) för centrala delar av stacken
- [ ] Deploya stacken från kod
- [ ] Visa versionshantering (ändring och historik)
- [ ] Dokumentera hur stacken återskapas

### [v47 — Skalbarhet och tillgänglighet](v47/README.md)
- [ ] Skapa avsnitt för v47 och uppdatera README
- [ ] Skapa ett launch template för WordPress-instansen
- [ ] Sätt upp en Auto Scaling-grupp över flera Availability Zones
- [ ] Placera en Application Load Balancer med health checks framför gruppen
- [ ] Beräkna månadskostnaden med AWS Pricing Calculator
- [ ] Verifiera och dokumentera

### [v48 — Monitorering och cloud native](v48/README.md)
- [ ] Skapa avsnitt för v48 och uppdatera README
- [ ] Sätt upp CloudWatch för CPU, minne, disk och loggning med larm
- [ ] Samla loggar centralt
- [ ] Kör en del av lösningen som container eller serverless (eller redogör för en cloud native-strategi)
- [ ] Förklara och dokumentera
