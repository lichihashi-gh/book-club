@RestResource(urlMapping='/accounts/*')
global with sharing class AccountApi {
    @HttpGet
    global static List<AccountResponse> getAccounts() {
        RestRequest request = RestContext.request;
        String searchTerm = request.params.get('search');
        Integer requestedLimit = parseLimit(request.params.get('limit'));

        String escapedSearch = String.isBlank(searchTerm)
            ? ''
            : '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';

        String soql = 'SELECT Id, Name, Industry, Phone '
            + 'FROM Account ';
        if (String.isNotBlank(escapedSearch)) {
            soql += 'WHERE Name LIKE :escapedSearch ';
        }
        soql += 'WITH SECURITY_ENFORCED '
            + 'ORDER BY Name ASC LIMIT :requestedLimit';

        List<Account> accounts = Database.query(soql);
        List<AccountResponse> response = new List<AccountResponse>();

        for (Account accountRecord : accounts) {
            response.add(new AccountResponse(accountRecord));
        }
        return response;
    }

    private static Integer parseLimit(String value) {
        if (String.isBlank(value)) {
            return 20;
        }
        try {
            return Math.max(1, Math.min(200, Integer.valueOf(value)));
        } catch (Exception e) {
            return 20;
        }
    }

    global class AccountResponse {
        global Id id;
        global String name;
        global String industry;
        global String phone;

        global AccountResponse(Account accountRecord) {
            id = accountRecord.Id;
            name = accountRecord.Name;
            industry = accountRecord.Industry;
            phone = accountRecord.Phone;
        }
    }
}
